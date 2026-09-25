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

  stateDir = "/var/lib/ksmbd";
  pwddbPath = "${stateDir}/ksmbdpwd.db";

  # Bound onto ksmbd.mountd's /run (see BindPaths) so ksmbd-config can
  # update the config of a running daemon; store paths and credentials are
  # both fixed at unit start.
  runtimeDir = "/run/ksmbd";
  inner = path: "/run" + lib.removePrefix runtimeDir path;

  confPath = "${runtimeDir}/ksmbd.conf";
  nssNamesPath = "${runtimeDir}/nss-names";

  # Interfaces ksmbd binds to, with the netns their link bounce has to
  # happen in (null = root netns).
  mkHostInterface = host: {
    name = foxDenLib.hosts.getInterfaceName config host;
    netns = (foxDenLib.hosts.getByName config host).namespace;
    routes = (foxDenLib.hosts.getInterface config host).routes or [ ];
  };
  hostInterfaces = map mkHostInterface ([ svcConfig.host ] ++ svcConfig.extraHosts);
  interfaceNames = (map (iface: iface.name) hostInterfaces) ++ svcConfig.extraInterfaces;

  hostUnits = map (host: (foxDenLib.hosts.getByName config host).unit) svcConfig.extraHosts;

  # kanidm-unixd is not ordered before nss-user-lookup.target, so name it.
  nssUnits = [
    "nss-user-lookup.target"
  ]
  ++ lib.optional config.services.kanidm.unix.enable "kanidm-unixd.service";

  # Every user/group name ksmbd.mountd has to resolve through NSS. As in
  # Samba, "@name" in a user list means a group.
  splitNames = s: lib.filter (n: n != "") (lib.splitString " " s);
  namesFromKeys =
    keys:
    lib.unique (
      lib.concatMap (section: lib.concatMap (key: splitNames (section.${key} or "")) keys) (
        lib.attrValues svcConfig.settings
      )
    );
  userListNames = namesFromKeys [
    "admin users"
    "force user"
    "guest account"
    "invalid users"
    "read list"
    "valid users"
    "write list"
  ];
  nssUserNames = lib.filter (n: !lib.hasPrefix "@" n) userListNames;
  nssGroupNames = lib.unique (
    map (lib.removePrefix "@") (lib.filter (lib.hasPrefix "@") userListNames)
    ++ namesFromKeys [ "force group" ]
  );

  # Has to stay under the unit's TimeoutStartSec, which ExecStartPre counts
  # against.
  nssTimeout = 60;

  # A data file rather than part of waitForNss, so new users don't change
  # ksmbd.service and force a restart.
  nssNames = pkgs.writeText "ksmbd-nss-names" (
    lib.concatMapStrings (name: "passwd ${name}\n") nssUserNames
    + lib.concatMapStrings (name: "group ${name}\n") nssGroupNames
  );

  # ksmbd.mountd resolves each pwddb user once at load and never retries.
  # An unresolved name is silently mapped to uid 65535, so auth succeeds but
  # every file access fails with EACCES. Wait until NSS resolves all names.
  waitForNss = pkgs.writeShellApplication {
    name = "ksmbd-wait-for-nss";
    runtimeInputs = [
      pkgs.getent
      pkgs.coreutils
    ];
    text = ''
      names=${inner nssNamesPath}
      if [ ! -f "$names" ]; then
        # ksmbd-config.service is Before= this unit and writes the list, so
        # this means that unit was bypassed. Unguarded beats no SMB at all.
        echo "no NSS name list at $names; starting unguarded" >&2
        exit 0
      fi

      deadline=$(( $(date +%s) + ${toString nssTimeout} ))
      while :; do
        unresolved=0
        while read -r db name; do
          [ -n "$db" ] || continue
          if ! getent "$db" "$name" >/dev/null; then
            echo "still unresolved: $db entry $name"
            unresolved=1
          fi
        done < "$names"
        if [ "$unresolved" -eq 0 ]; then
          exit 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
          break
        fi
        sleep 1
      done
      # Better than leaving SMB down entirely.
      echo "giving up after ${toString nssTimeout}s; shares for the names above will deny access until ksmbd is reloaded" >&2
    '';
  };

  toConf = lib.generators.toINI { mkKeyValue = k: v: "${k} = ${toString v}"; };

  ksmbdConf = pkgs.writeText "ksmbd.conf" (toConf svcConfig.settings);

  # Shares and the pwddb apply on reload, but [global] is only sent to the
  # kernel at startup, so it alone triggers a restart.
  globalConf = pkgs.writeText "ksmbd-global.conf" (toConf {
    global = svcConfig.settings.global or { };
  });

  # Installs the live config and reloads ksmbd. Unconfined so it sees this
  # generation's store paths while an older daemon is still running.
  installConfig = pkgs.writeShellApplication {
    name = "ksmbd-install-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      install -d -m 0700 ${runtimeDir}
      # Atomic rename: a half-written config would crash the daemon on reload.
      install -m 0600 ${ksmbdConf} ${confPath}.new
      install -m 0600 ${nssNames} ${nssNamesPath}.new
      mv -f ${confPath}.new ${confPath}
      mv -f ${nssNamesPath}.new ${nssNamesPath}

      # At boot this runs before ksmbd.service, so there is nothing to
      # reload and these files are simply what it starts with.
      if systemctl is-active --quiet ksmbd.service; then
        # --no-block avoids deadlocking when the same switch restarts ksmbd.
        systemctl reload --no-block ksmbd.service ||
          echo "could not reload ksmbd.service; it is likely restarting anyway" >&2
      fi
    '';
  };

  # ksmbd only creates a listener on NETDEV_UP for a configured interface,
  # in the netns of whoever triggered it. So bounce each interface from
  # inside its netns, retrying in case mountd hasn't registered it yet.
  bounceInterface = pkgs.writeShellApplication {
    name = "ksmbd-bounce-interface";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.coreutils
      pkgs.sysctl
    ];
    text =
      let
        nsPrefix =
          iface: if iface.netns == null then "" else "ip netns exec ${lib.escapeShellArg iface.netns} ";
        forEach = f: lib.concatMapStrings (iface: "${f iface}\n") hostInterfaces;
      in
      ''
        # Bouncing drops IPv6 addresses and routes; keep the former and
        # restore the latter.
        ${forEach (iface: "${nsPrefix iface}sysctl -qw net.ipv6.conf.${iface.name}.keep_addr_on_down=1")}
        for _ in 1 2 3 4 5; do
          sleep 1
          ${forEach (
            iface:
            "${nsPrefix iface}ip link set ${lib.escapeShellArg iface.name} down; ${nsPrefix iface}ip link set ${lib.escapeShellArg iface.name} up"
          )}
        done
        ${forEach (
          iface:
          lib.concatMapStringsSep "\n" (
            route: "${foxDenLib.hosts.renderRoute "${nsPrefix iface}ip" iface.name route} || true"
          ) (if iface.routes == null then [ ] else iface.routes)
        )}
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
        description = ''
          Filesystems the shares live on, purely for mount ordering.

          Not bound into ksmbd.mountd's chroot: the kernel does all file
          access, and binding them would make share changes a restart.
        '';
      };
      smbDirect = lib.mkEnableOption ''
        SMB Direct (SMB over RDMA).

        Rebuilds the kernel with SMB_SERVER_SMBDIRECT; without it RDMA
        connects are rejected silently. Needs an RDMA-capable interface in
        the root netns'';
      extraHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "nas" ];
        description = ''
          Additional foxDen hosts to listen on beyond {option}`host`, in
          whatever netns they live in.
        '';
      };
      extraInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "br-default" ];
        description = ''
          Additional interface names, by literal name, to listen on.

          Never bounced, so they only work if brought up after ksmbd
          starts. Prefer {option}`extraHosts`.
        '';
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
        # ksmbd has no VFS module framework, so there is no Samba-style
        # catia/fruit macOS setup or fruit:* tuning to configure here.
        foxDen.services.ksmbd.settings.global = {
          "workgroup" = "WORKGROUP";
          "server string" = "FoxDen kSMBd";
          "guest account" = "smbguest";
          "map to guest" = "never";
          "server min protocol" = "SMB2_10";
          "server max protocol" = "SMB3_11";
          "server multi channel support" = "yes";
          "smb3 encryption" = "auto";
          # Otherwise ksmbd binds any interface that comes up, including
          # management. TCP only: SMB Direct always binds everything in the
          # root netns.
          "interfaces" = lib.concatStringsSep " " interfaceNames;
          "bind interfaces only" = "yes";
        };

        users.users.smbguest = {
          isSystemUser = true;
          group = "smbguest";
        };
        users.groups.smbguest = { };

        boot.kernelModules = [ "ksmbd" ];

        boot.kernelPatches = lib.optional svcConfig.smbDirect {
          name = "ksmbd-smbdirect";
          patch = null;
          structuredExtraConfig = {
            SMB_SERVER_SMBDIRECT = lib.kernel.yes;
          };
        };

        environment.systemPackages = [
          pkgs.ksmbd-tools
        ];

        # Holds everything share-specific, so share changes reload ksmbd
        # instead of restarting it and dropping sessions.
        systemd.services.ksmbd-config = {
          description = "Install ksmbd's live configuration and reload ksmbd";
          requiredBy = [ "ksmbd.service" ];
          before = [ "ksmbd.service" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          unitConfig.RequiresMountsFor = svcConfig.sharePaths;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${installConfig}/bin/ksmbd-install-config";
          };
        };

        # Unconfined: `ip netns exec` needs the real /run/netns.
        systemd.services.ksmbd-bounce-interface = {
          description = "Bounce ksmbd's SMB interfaces to force a namespaced socket bind";
          after = [ "ksmbd.service" ] ++ hostUnits;
          requires = hostUnits;
          # Re-bounce when an extra host's interface comes back.
          partOf = [ "ksmbd.service" ] ++ hostUnits;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${bounceInterface}/bin/ksmbd-bounce-interface";
          };
        };

        systemd.services.ksmbd = {
          description = "ksmbd userspace daemon";
          wantedBy = [ "multi-user.target" ];
          wants = [ "ksmbd-bounce-interface.service" ] ++ nssUnits;
          after = hostUnits ++ nssUnits;
          # See globalConf.
          restartTriggers = [ globalConf ];
          serviceConfig = {
            ExecStartPre = "${waitForNss}/bin/ksmbd-wait-for-nss";
            # The kernel only sends IPC to a mountd in the root netns;
            # listeners are placed by bounceInterface instead.
            NetworkNamespacePath = lib.mkForce null;
            # Netlink needs CAP_NET_ADMIN in the init user namespace.
            PrivateUsers = lib.mkForce false;
            ExecStart = "${pkgs.ksmbd-tools}/bin/ksmbd.mountd --nodetach --config=${inner confPath} --pwddb=${pwddbPath}";
            ExecReload = "${pkgs.ksmbd-tools}/bin/ksmbd.control --reload";
            ExecStop = "${pkgs.ksmbd-tools}/bin/ksmbd.control --shutdown";
            # /run is shared between Exec* lines so ksmbd.control can find
            # the hardcoded /run/ksmbd.lock. A directory, since mountd
            # renames onto the lock file.
            BindPaths = [
              stateDir
              "${runtimeDir}:/run"
              # Writable for --shutdown, else the next start keeps the old
              # interface list.
              "/sys/class/ksmbd-control"
            ];
            BindReadOnlyPaths =
              services.mkEtcPaths [
                "nsswitch.conf"
                "fstab"
                "mtab"
              ]
              ++ [
                # NSS modules (kanidm) are only reachable through nscd.
                "-/var/run/nscd"
              ];
          };
        };

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0700 root root - -"
          "d ${runtimeDir} 0700 root root - -"
          "f ${pwddbPath} 0600 root root - -"
        ];

        environment.persistence."/nix/persist/ksmbd" = {
          hideMounts = true;
          directories = [
            {
              directory = stateDir;
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
