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
  netnsName = (foxDenLib.hosts.getByName config svcConfig.host).namespace;

  ksmbdConf = pkgs.writeText "ksmbd.conf" (
    lib.generators.toINI { mkKeyValue = k: v: "${k} = ${toString v}"; } svcConfig.settings
  );

  # ksmbd's kernel module only ever creates a listening socket in response
  # to a live NETDEV_UP notification for a *named* interface (matched by a
  # global, all-namespaces netdevice notifier - see ksmbd_netdev_event() in
  # fs/smb/server/transport_tcp.c) - ksmbd.mountd's own startup IPC just
  # registers the name, it never binds anything itself. The netns the
  # resulting socket lands in comes from whichever process's syscall
  # context triggers that NETDEV_UP event, not from ksmbd.mountd's own
  # netns (ksmbd.mountd deliberately runs in the root netns here - see
  # the PrivateUsers comment below) - so this explicitly triggers it from
  # inside the target netns via `ip netns exec`, exactly as confirmed
  # live: bouncing the link that way is what moved the listener from the
  # root netns into host-nas, independent of where ksmbd.mountd itself
  # was running at the time. Retried a few times since this can start
  # before ksmbd.mountd has actually registered the interface name.
  bounceInterface = pkgs.writeShellApplication {
    name = "ksmbd-bounce-interface";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.coreutils
    ];
    text = ''
      for _ in 1 2 3 4 5; do
        sleep 1
        ip netns exec ${lib.escapeShellArg netnsName} ip link set ${lib.escapeShellArg netInterfaceName} down
        ip netns exec ${lib.escapeShellArg netnsName} ip link set ${lib.escapeShellArg netInterfaceName} up
      done
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
          # ksmbd.mountd runs in the root netns (see the PrivateUsers
          # comment below), which also has the management interface - this
          # name-based pin is what keeps it off that interface, since
          # netdevice matching happens by name regardless of ksmbd.mountd's
          # own netns. Without it, ksmbd auto-binds *any* interface,
          # anywhere on the host, that gets a NETDEV_UP event while
          # unconfigured - including the management one.
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
        ];

        # Runs unconfined (not through services.make) deliberately: it just
        # needs `ip netns exec` against the real host /run/netns, and
        # fighting ksmbd.service's own confined chroot for that (`ip netns`
        # looks under /var/run/netns, which doesn't reliably resolve to
        # /run/netns inside a confined root the way it does on the host)
        # isn't worth it for a one-shot link bounce. partOf ties its
        # lifecycle to ksmbd.service: stopping/restarting that stops/
        # restarts this too, and `wants` on ksmbd.service is what actually
        # starts it after ksmbd.mountd itself comes up.
        systemd.services.ksmbd-bounce-interface = {
          description = "Bounce ksmbd's SMB interface to force a namespaced socket bind";
          after = [ "ksmbd.service" ];
          partOf = [ "ksmbd.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${bounceInterface}/bin/ksmbd-bounce-interface";
          };
        };

        systemd.services.ksmbd = {
          description = "ksmbd userspace daemon";
          wantedBy = [ "multi-user.target" ];
          wants = [ "ksmbd-bounce-interface.service" ];
          serviceConfig = {
            # fs/smb/server/transport_ipc.c unicasts every kernel-initiated
            # message to ksmbd.mountd (login requests, share-config
            # requests, etc. - everything except the reply to ksmbd.mountd's
            # own startup message) with genlmsg_unicast(&init_net, skb,
            # ksmbd_tools_pid) - hardcoded to the root netns, unconditionally,
            # in the current upstream kernel source. If ksmbd.mountd's own
            # control socket is created in a different netns (e.g. via
            # NetworkNamespacePath), the kernel can never find it there and
            # every such message times out - confirmed live: this is what was
            # behind "Unknown user name or an error" rejecting every login,
            # regardless of credentials, once ksmbd.mountd ran confined to
            # host-nas. So ksmbd.mountd has to run in the root netns; see the
            # "interfaces" comment above and the bounceInterface comment for
            # how the actual SMB listener still ends up confined to
            # host-nas's interface despite that. (ksmbd.control's own
            # --reload/--shutdown, which use a plain kill() rather than this
            # netlink path, are a separate, still-unresolved issue - use a
            # full service restart instead for now.)
            NetworkNamespacePath = lib.mkForce null;
            # Still needed even in the root netns: that same netlink_capable()
            # CAP_NET_ADMIN check is against the target netns's *owning user
            # namespace* (init_net's is the real, non-private init_user_ns),
            # and a PrivateUsers=true confined user namespace (the
            # confinement.enable default from services.make) can never pass
            # that check - capabilities in a child user namespace never
            # grant privilege in an ancestor one.
            PrivateUsers = lib.mkForce false;
            ExecStart = "${pkgs.ksmbd-tools}/bin/ksmbd.mountd -v --nodetach --config=\${CREDENTIALS_DIRECTORY}/ksmbd.conf --pwddb=${pwddbPath}";
            ExecReload = "${pkgs.ksmbd-tools}/bin/ksmbd.control -v --reload";
            ExecStop = "${pkgs.ksmbd-tools}/bin/ksmbd.control -v --shutdown";
            LoadCredential = "ksmbd.conf:${ksmbdConf}";
            # /run/ksmbd.lock is intentionally not bound to a host path:
            # ExecStart/ExecReload/ExecStop all share this unit's private,
            # confined /run, so ksmbd.mountd's own lock-file bookkeeping
            # (a temp-file-then-rename) stays self-consistent there. Bind
            # mounting the file itself made rename() fail with EBUSY
            # (can't rename onto an active mount point).
            BindPaths = [ "/var/lib/ksmbd" ] ++ svcConfig.sharePaths;
            BindReadOnlyPaths =
              services.mkEtcPaths [
                "nsswitch.conf"
                "fstab"
                "mtab"
              ]
              ++ [
                # NixOS's system.nssModules (kanidm's NSS module included)
                # is resolved through nscd, not dlopen()'d directly by the
                # querying process - without its socket, NSS lookups for
                # kanidm-backed users (doridian, wizzy) fail inside the
                # confined root and ksmbd rejects them with "Unknown user
                # name or an error", even with the right password. Same
                # bind samba.nix already carries for the same reason.
                "-/var/run/nscd"
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
