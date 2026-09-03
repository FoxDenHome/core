{
  pkgs,
  foxDenLib,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.ksmbd;

  pwddbPath = "/var/lib/ksmbd/ksmbdpwd.db";

  # The actual in-netns name of the interface ksmbd needs to bind to.
  netInterfaceName = foxDenLib.hosts.getInterfaceName config svcConfig.host;

  ksmbdConf = pkgs.writeText "ksmbd.conf" (
    lib.generators.toINI { mkKeyValue = k: v: "${k} = ${toString v}"; } svcConfig.settings
  );

  # ksmbd's kernel module only ever creates a listening socket in response
  # to a live NETDEV_UP notification for a *named* interface (matched by a
  # global, all-namespaces netdevice notifier - see ksmbd_netdev_event() in
  # fs/smb/server/transport_tcp.c) - ksmbd.mountd's own startup IPC just
  # registers the name, it never binds anything itself. Since the netns's
  # interface is already up long before ksmbd.mountd starts, that live
  # event never happens on its own, so the socket never gets created in
  # the right netns (or anywhere, if it's genuinely never re-triggered).
  # Bouncing the link from inside the netns after startup forces that
  # event to fire with the correct namespace as "current" at that moment.
  # Retried a few times since ExecStartPost can start before ksmbd.mountd
  # has actually finished registering the interface name with the kernel.
  bounceInterface = pkgs.writeShellApplication {
    name = "ksmbd-bounce-interface";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      for _ in 1 2 3 4 5; do
        sleep 1
        ip link set ${lib.escapeShellArg netInterfaceName} down
        ip link set ${lib.escapeShellArg netInterfaceName} up
      done
    '';
  };

  # ksmbd uses the same NT hash (MD4 of the UTF-16LE password) that Samba's
  # passdb stores, just base64-encoded instead of hex-encoded, so users can
  # move over without picking new passwords.
  migrateSambaUsers = pkgs.writeShellApplication {
    name = "ksmbd-migrate-samba-users";
    runtimeInputs = [
      pkgs.samba
      pkgs.coreutils
      pkgs.xxd
    ];
    text = ''
      pwddb=''${1:-${pwddbPath}}
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT

      : > "$tmp"
      while IFS=: read -r user _uid _lm nt _rest; do
        [ -z "$user" ] && continue
        if ! [[ "$nt" =~ ^[0-9A-Fa-f]{32}$ ]]; then
          echo "ksmbd-migrate-samba-users: skipping $user (no usable NT hash)" >&2
          continue
        fi
        b64=$(echo "$nt" | xxd -r -p | base64 -w0)
        echo "$user:$b64" >> "$tmp"
      done < <(pdbedit -L -w)

      install -m 0600 -o root -g root "$tmp" "$pwddb"
      echo "ksmbd-migrate-samba-users: wrote $(wc -l < "$pwddb") user(s) to $pwddb" >&2
      echo "ksmbd-migrate-samba-users: run 'systemctl reload ksmbd' to apply" >&2
    '';
  };
in
{
  options.foxDen.services.ksmbd = (
    (services.mkOptions {
      name = "ksmbd, for SMB";
    })
    // {
      sharePaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Directories to share over SMB via ksmbd";
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = { };
        description = "ksmbd.conf sections, shaped like services.samba.settings";
      };
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "ksmbd";
      }).config
      {
        # ksmbd has no VFS module framework, so there is no equivalent to
        # Samba's catia/fruit/streams_xattr macOS setup here - only
        # acl_xattr and streams_xattr exist, and there's no fruit:* tuning.
        foxDen.services.ksmbd.settings.global = {
          "workgroup" = "WORKGROUP";
          "guest account" = "smbguest";
          "map to guest" = "never";
          "server min protocol" = "SMB2_10";
          "server max protocol" = "SMB3_11";
          "server multi channel support" = "yes";
          "smb3 encryption" = "auto";
          # Without this, ksmbd auto-binds to *any* interface, anywhere on
          # the host, that gets a NETDEV_UP event while unconfigured - see
          # the netInterfaceName/bounceInterface comment below. Pinning it
          # here is also required for the bounce to end up matching this
          # netns's interface by name at all.
          "interfaces" = netInterfaceName;
          "bind interfaces only" = "yes";
        };

        users.users.smbguest = {
          isSystemUser = true;
          group = "smbguest";
        };
        users.groups.smbguest = { };

        boot.kernelModules = [ "ksmbd" ];

        environment.systemPackages = [
          pkgs.ksmbd-tools
          migrateSambaUsers
        ];

        systemd.services.ksmbd = {
          description = "ksmbd userspace daemon";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            # The ksmbd kernel module gates every control/config netlink
            # message with netlink_capable(skb, CAP_NET_ADMIN), which is
            # checked against the *owning user namespace of the target
            # netns* (host-nas's, created by real root), not the calling
            # task's own. A PrivateUsers=true confined user namespace (the
            # confinement.enable default from services.make) can never
            # pass that check - capabilities in a child user namespace
            # never grant privilege in an ancestor one - so ksmbd.mountd
            # would get EPERM setting up its listener. Samba never hit
            # this because plain TCP bind() only checks capabilities
            # against the caller's own (possibly private) user namespace.
            PrivateUsers = lib.mkForce false;
            ExecStart = "${pkgs.ksmbd-tools}/bin/ksmbd.mountd --nodetach --config=\${CREDENTIALS_DIRECTORY}/ksmbd.conf --pwddb=${pwddbPath}";
            ExecStartPost = "${bounceInterface}/bin/ksmbd-bounce-interface";
            ExecReload = "${pkgs.ksmbd-tools}/bin/ksmbd.control --reload";
            ExecStop = "${pkgs.ksmbd-tools}/bin/ksmbd.control --shutdown";
            LoadCredential = "ksmbd.conf:${ksmbdConf}";
            # /run/ksmbd.lock is intentionally not bound to a host path:
            # ExecStart/ExecReload/ExecStop all share this unit's private,
            # confined /run, so ksmbd.mountd's own lock-file bookkeeping
            # (a temp-file-then-rename) stays self-consistent there. Bind
            # mounting the file itself made rename() fail with EBUSY
            # (can't rename onto an active mount point).
            BindPaths = [ "/var/lib/ksmbd" ] ++ svcConfig.sharePaths;
            BindReadOnlyPaths = services.mkEtcPaths [
              "nsswitch.conf"
              "fstab"
              "mtab"
            ];
          };
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/ksmbd 0700 root root - -"
          "f ${pwddbPath} 0600 root root - -"
        ];

        environment.persistence."/nix/persist/ksmbd" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/ksmbd";
              user = "root";
              group = "root";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
