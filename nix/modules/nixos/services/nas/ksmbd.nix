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

  # Bind-mounted onto ksmbd.mountd's own /run (see BindPaths), so what the
  # ksmbd-config unit drops here is what the *running* daemon reads - the
  # only way a config change reaches it without a restart. A store path
  # can't be: the confinement chroot only carries the closure of the Exec*
  # lines as of unit start, and LoadCredential is snapshotted at ExecStart
  # and never refreshed for an ExecReload.
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

  # nixpkgs' kanidm-unixd is not ordered before nss-user-lookup.target, so
  # name its unit directly. It stays "activating" until its providers are
  # up, so a plain After= covers the whole window.
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

  # Kept as data rather than baked into waitForNss's text: a script listing
  # the names would sit in ksmbd.service's ExecStartPre, so every new user a
  # share brings in would change the unit and force the very restart adding
  # a share is meant to avoid.
  nssNames = pkgs.writeText "ksmbd-nss-names" (
    lib.concatMapStrings (name: "passwd ${name}\n") nssUserNames
    + lib.concatMapStrings (name: "group ${name}\n") nssGroupNames
  );

  # ksmbd.mountd resolves each pwddb user with a single getpwnam() as it
  # loads the db (new_ksmbd_user() in tools/management/user.c) and never
  # retries. A name that does not resolve right then is silently pinned to
  # uid/gid 65535 with no supplementary groups; auth and the "valid users"
  # check still pass (both work off the pwddb and the name), but file access
  # runs as 65535 with the fs capability set dropped, so a mode 0700 home
  # returns EACCES for everything - a share that mounts fine and then denies
  # even readdir. Seen here when ksmbd.mountd beat kanidm-unixd up by ~6s.
  #
  # nssUnits orders around that race; this gate confirms it, through the
  # same NSS path mountd will use, before mountd reads the pwddb.
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
      # Starting anyway beats leaving SMB down over a name that is never
      # coming back, but say so loudly: shares using it serve EACCES until
      # this unit is reloaded.
      echo "giving up after ${toString nssTimeout}s; shares for the names above will deny access until ksmbd is reloaded" >&2
    '';
  };

  toConf = lib.generators.toINI { mkKeyValue = k: v: "${k} = ${toString v}"; };

  ksmbdConf = pkgs.writeText "ksmbd.conf" (toConf svcConfig.settings);

  # The half of the config a reload cannot apply, split out so it can be
  # ksmbd.service's restart trigger. SIGHUP makes ksmbd.mountd re-run
  # load_config() (mountd/mountd.c), so the pwddb and every share section -
  # including whole shares appearing and disappearing - are live. [global]
  # is not: it reaches the kernel only through the one
  # KSMBD_EVENT_STARTING_UP message ipc_init() sends, and ipc_init() returns
  # early on a reload because its netlink socket is already open
  # (mountd/ipc.c).
  globalConf = pkgs.writeText "ksmbd-global.conf" (toConf {
    global = svcConfig.settings.global or { };
  });

  # Writes the two files ksmbd.mountd reads out of its own /run, then asks a
  # running daemon to pick them up. Unconfined on purpose: it has to see
  # *this* generation's store paths while a daemon started by an older one
  # is still running.
  installConfig = pkgs.writeShellApplication {
    name = "ksmbd-install-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      install -d -m 0700 ${runtimeDir}
      # Renamed into place: a reload racing the write would otherwise read a
      # half-file, and a config that fails to parse takes the daemon down
      # rather than being ignored (worker_init() in mountd/mountd.c).
      install -m 0600 ${ksmbdConf} ${confPath}.new
      install -m 0600 ${nssNames} ${nssNamesPath}.new
      mv -f ${confPath}.new ${confPath}
      mv -f ${nssNamesPath}.new ${nssNamesPath}

      # At boot this runs before ksmbd.service, so there is nothing to
      # reload and these files are simply what it starts with.
      if systemctl is-active --quiet ksmbd.service; then
        # --no-block: this unit is ordered before ksmbd.service, so waiting
        # on its job would deadlock whenever the same switch also restarts
        # it (a [global] change) - and that restart absorbs the reload.
        systemctl reload --no-block ksmbd.service ||
          echo "could not reload ksmbd.service; it is likely restarting anyway" >&2
      fi
    '';
  };

  # The kernel only creates a listening socket in response to a live
  # NETDEV_UP for a *named* interface (ksmbd_netdev_event() in
  # fs/smb/server/transport_tcp.c, a global all-namespaces notifier);
  # ksmbd.mountd's startup IPC merely registers the name. The socket lands
  # in the netns of whatever process's syscall triggered NETDEV_UP, not
  # ksmbd.mountd's own (it runs in the root netns - see PrivateUsers), hence
  # the `ip netns exec`. Interfaces already in the root netns are bounced
  # without the prefix. Retried, since this can run before ksmbd.mountd has
  # registered the interface name.
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
        # A link going down otherwise drops the interface's IPv6 addresses
        # and every route through it, which the netns unit only ever sets up
        # once - so keep the addresses and put the routes back.
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

          ksmbd.mountd never touches a share's path - it only forwards the
          string to the kernel (shm_handle_share_config_request() in
          tools/management/share.c), which does every file operation from a
          kthread in the root mount namespace. So these are deliberately
          *not* bound into ksmbd.mountd's chroot: that would put the share
          list in ksmbd.service's own unit, making every added or removed
          share a restart instead of a reload. The RequiresMountsFor= those
          binds used to imply lives on ksmbd-config.service instead.
        '';
      };
      smbDirect = lib.mkEnableOption ''
        SMB Direct (SMB over RDMA).

        Compile-time only: ksmbd's RDMA listener does not exist unless the
        kernel is built with SMB_SERVER_SMBDIRECT, so this rebuilds the
        kernel. Without it the RDMA core rejects a client's connect with
        IB_CM_REJ_INVALID_SERVICE_ID before ksmbd sees anything, so nothing
        is logged however verbose it is set to.

        Needs an RDMA-capable interface in the root netns to be of any use
        - see the "interfaces" comment below'';
      extraHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "nas" ];
        description = ''
          Additional foxDen hosts to listen on beyond {option}`host`. Their
          interface is bounced in whatever netns it lives in, so a host in
          its own netns can serve plain TCP clients alongside a root netns
          one doing SMB Direct.
        '';
      };
      extraInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "br-default" ];
        description = ''
          Additional interface names, by literal name, to listen on.

          Unlike {option}`extraHosts` these are never bounced, so they only
          work for interfaces something else already brought up while ksmbd
          knew about them. Prefer {option}`extraHosts`.
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
          "guest account" = "smbguest";
          "map to guest" = "never";
          "server min protocol" = "SMB2_10";
          "server max protocol" = "SMB3_11";
          "server multi channel support" = "yes";
          "smb3 encryption" = "auto";
          # ksmbd.mountd runs in the root netns (see PrivateUsers), which
          # also holds the management interface, and netdevice matching is
          # by name regardless of netns - so without this pin ksmbd
          # auto-binds *any* interface on the host that gets a NETDEV_UP
          # while unconfigured, the management one included.
          #
          # TCP transport only. ksmbd_rdma_init() binds INADDR_ANY once, at
          # daemon startup, from a system_long_wq kworker, so SMB Direct
          # always lands in init_net and covers everything visible there: an
          # interface inside a netns can never serve it, no matter what this
          # says or what gets bounced afterwards.
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

        # The only unit that knows what the shares are, so a change to them
        # restarts *this* no-op oneshot and reloads ksmbd rather than
        # restarting the daemon and dropping every SMB session. Unconfined
        # for the reason given in the installConfig comment.
        systemd.services.ksmbd-config = {
          description = "Install ksmbd's live configuration and reload ksmbd";
          # requiredBy rather than a Requires= on ksmbd.service: the
          # dependency then lives in a .requires symlink, keeping anything
          # share-shaped out of ksmbd.service's unit text.
          requiredBy = [ "ksmbd.service" ];
          before = [ "ksmbd.service" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          # What binding the share paths into ksmbd.service's chroot used to
          # give implicitly - see sharePaths. Not a dependency of
          # ksmbd.service, so a share's filesystem going away no longer
          # takes the whole daemon with it.
          unitConfig.RequiresMountsFor = svcConfig.sharePaths;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${installConfig}/bin/ksmbd-install-config";
          };
        };

        # Unconfined (not through services.make) deliberately: it just needs
        # `ip netns exec` against the real host /run/netns, which does not
        # reliably resolve inside ksmbd.service's confined root. partOf ties
        # its lifecycle to ksmbd.service; ksmbd.service's `wants` is what
        # starts it once ksmbd.mountd is up.
        systemd.services.ksmbd-bounce-interface = {
          description = "Bounce ksmbd's SMB interfaces to force a namespaced socket bind";
          after = [ "ksmbd.service" ] ++ hostUnits;
          requires = hostUnits;
          # partOf the extra hosts too, so an interface that comes back
          # without ksmbd itself restarting gets its listener re-created.
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
          # Nothing else in this unit varies with the config, so this forces
          # a restart for exactly the [global] settings a reload cannot
          # reach. See globalConf.
          restartTriggers = [ globalConf ];
          serviceConfig = {
            # See waitForNss: without this a name NSS cannot resolve at this
            # exact moment is pinned to uid/gid 65535 for the lifetime of
            # the daemon, and its share denies everything.
            ExecStartPre = "${waitForNss}/bin/ksmbd-wait-for-nss";
            # transport_ipc.c unicasts every kernel-initiated message
            # (logins, share-config requests, everything but the reply to
            # mountd's own startup message) with genlmsg_unicast(&init_net,
            # ...) - hardcoded to the root netns. With mountd's control
            # socket in another netns the kernel never finds it and every
            # login fails with "Unknown user name or an error". The SMB
            # listener still ends up confined to host-nas's interface - see
            # the "interfaces" and bounceInterface comments. (ksmbd.control
            # --reload/--shutdown use kill(), not this path - see BindPaths.)
            NetworkNamespacePath = lib.mkForce null;
            # Still needed even in the root netns: netlink_capable() checks
            # CAP_NET_ADMIN against the target netns's owning user namespace
            # (init_net's is the real init_user_ns), and a PrivateUsers=true
            # child user namespace - the confinement default from
            # services.make - can never pass that.
            PrivateUsers = lib.mkForce false;
            ExecStart = "${pkgs.ksmbd-tools}/bin/ksmbd.mountd --nodetach --config=${inner confPath} --pwddb=${pwddbPath}";
            ExecReload = "${pkgs.ksmbd-tools}/bin/ksmbd.control --reload";
            ExecStop = "${pkgs.ksmbd-tools}/bin/ksmbd.control --shutdown";
            # ksmbd-tools hardcodes its lock file at /run/ksmbd.lock (no CLI
            # override), and each Exec* gets its own fresh, empty private
            # /run under confinement, so ksmbd.control could never find the
            # PID to signal - every --reload/--shutdown failed with "Can't
            # notify mountd". Binding the bare file breaks ksmbd.mountd's
            # write-temp-then-rename onto it (EBUSY), so remap a dedicated
            # host directory onto the confined root's /run instead: mountd
            # still writes the hardcoded /run/ksmbd.lock, which really means
            # /run/ksmbd/ksmbd.lock on the host, without exposing the real
            # /run and every other service's runtime state.
            BindPaths = [
              stateDir
              "${runtimeDir}:/run"
              # ExecStop's --shutdown writes to
              # /sys/class/ksmbd-control/kill_server, which confinement
              # (plus ProtectKernelTunables) leaves read-only ("Can't kill
              # ksmbd"). The kernel then keeps ksmbd_tools_pid set, so the
              # next start takes transport_ipc.c's reconnect path, which
              # never re-runs ksmbd_tcp_set_interfaces: the interface list
              # and its sockets stay whatever the previous generation asked
              # for, so a newly added interface never gets a listener and a
              # removed one keeps serving.
              "/sys/class/ksmbd-control"
            ];
            BindReadOnlyPaths =
              services.mkEtcPaths [
                "nsswitch.conf"
                "fstab"
                "mtab"
              ]
              ++ [
                # system.nssModules (kanidm's included) are resolved through
                # nscd rather than dlopen()'d by the querying process, so
                # without its socket kanidm-backed users fail inside the
                # confined root and ksmbd rejects them with "Unknown user
                # name or an error" even with the right password. samba.nix
                # carries the same bind.
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
