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

  # The interfaces ksmbd needs to bind to, by their actual name plus the
  # netns the link bounce for them has to happen in (null = root netns).
  mkHostInterface = host: {
    name = foxDenLib.hosts.getInterfaceName config host;
    netns = (foxDenLib.hosts.getByName config host).namespace;
    routes = (foxDenLib.hosts.getInterface config host).routes or [ ];
  };
  hostInterfaces = map mkHostInterface ([ svcConfig.host ] ++ svcConfig.extraHosts);
  interfaceNames = (map (iface: iface.name) hostInterfaces) ++ svcConfig.extraInterfaces;

  hostUnits = map (host: (foxDenLib.hosts.getByName config host).unit) svcConfig.extraHosts;

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
  # inside the interface's own netns via `ip netns exec`, exactly as
  # confirmed live: bouncing the link that way is what moved the listener
  # from the root netns into host-nas, independent of where ksmbd.mountd
  # itself was running at the time. Interfaces that already live in the
  # root netns are bounced right here, without the prefix. Retried a few
  # times since this can start before ksmbd.mountd has actually
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
        # A link going down otherwise takes the interface's IPv6 addresses
        # and every route through it with it, which the netns unit only
        # ever sets up once - so keep the addresses and put the routes back.
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
        description = "Directories to share over SMB via ksmbd";
      };
      smbDirect = lib.mkEnableOption ''
        SMB Direct (SMB over RDMA).

        Compile-time only: ksmbd's RDMA listener does not exist unless the
        kernel is built with SMB_SERVER_SMBDIRECT, so this rebuilds the
        kernel. Without it a client's RDMA connect is rejected by the RDMA
        core with IB_CM_REJ_INVALID_SERVICE_ID before ksmbd sees anything,
        so nothing shows up in its log however verbose it is set to.

        Needs an RDMA-capable interface in the root netns to be of any use
        - see the "interfaces" comment below'';
      extraHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "nas" ];
        description = ''
          Additional foxDen hosts to listen on beyond {option}`host`, by
          name - their interface is resolved and bounced in whatever netns
          they live in, so a host in its own netns can serve plain TCP
          clients alongside a root netns one doing SMB Direct.
        '';
      };
      extraInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "br-default" ];
        description = ''
          Additional interface names, by literal name, to listen on beyond
          the one belonging to {option}`host`.

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
          #
          # Only applies to the TCP transport. The RDMA/SMB Direct listener
          # ignores this list entirely: ksmbd_rdma_init() binds INADDR_ANY
          # once, at daemon startup, from a system_long_wq kworker - so it
          # lands in init_net (kworkers inherit kthreadd's namespaces, never
          # the queueing task's) and covers every address visible there. An
          # interface inside a netns can therefore never serve SMB Direct,
          # no matter what this says or what gets bounced afterwards - only
          # a host with netns = false can.
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
          wants = [ "ksmbd-bounce-interface.service" ];
          after = hostUnits;
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
            # --reload/--shutdown use a plain kill() rather than this netlink
            # path - see the BindPaths comment below for that one.)
            NetworkNamespacePath = lib.mkForce null;
            # Still needed even in the root netns: that same netlink_capable()
            # CAP_NET_ADMIN check is against the target netns's *owning user
            # namespace* (init_net's is the real, non-private init_user_ns),
            # and a PrivateUsers=true confined user namespace (the
            # confinement.enable default from services.make) can never pass
            # that check - capabilities in a child user namespace never
            # grant privilege in an ancestor one.
            PrivateUsers = lib.mkForce false;
            ExecStart = "${pkgs.ksmbd-tools}/bin/ksmbd.mountd --nodetach --config=\${CREDENTIALS_DIRECTORY}/ksmbd.conf --pwddb=${pwddbPath}";
            ExecReload = "${pkgs.ksmbd-tools}/bin/ksmbd.control --reload";
            ExecStop = "${pkgs.ksmbd-tools}/bin/ksmbd.control --shutdown";
            LoadCredential = "ksmbd.conf:${ksmbdConf}";
            # ksmbd-tools hardcodes its lock file at /run/ksmbd.lock (no CLI
            # override exists). ExecStart/ExecReload/ExecStop each get their
            # own fresh, empty private /run under confinement (confirmed
            # live: ExecReload saw "Can't open `/run/ksmbd.lock': No such
            # file or directory" right after ExecStart had just written it),
            # so ksmbd.control could never find the PID it needs to signal -
            # every --reload/--shutdown failed with "Can't notify mountd".
            # Binding the bare file itself doesn't work either: it breaks
            # ksmbd.mountd's own write-temp-then-rename onto it (EBUSY,
            # can't rename onto an active mount point). So instead of
            # binding the file, or the host's whole (shared, much wider)
            # /run, remap a dedicated host directory onto the confined
            # root's /run entirely: ksmbd.mountd still writes to the
            # hardcoded /run/ksmbd.lock path from its own point of view,
            # but that now really means /run/ksmbd/ksmbd.lock on the host -
            # a real, persistent path every Exec* invocation shares,
            # without ever exposing this confined root to any other
            # service's sockets or runtime state under the real /run.
            BindPaths = [
              stateDir
              "/run/ksmbd:/run"
              # ExecStop's `ksmbd.control --shutdown` writes "hard" to
              # /sys/class/ksmbd-control/kill_server, and confinement (plus
              # ProtectKernelTunables) leaves /sys read-only, so that write
              # failed with "Can't kill ksmbd" - confirmed live. The kernel
              # then keeps ksmbd_tools_pid set, so the next start takes
              # transport_ipc.c's "Reconnect to a new user space daemon"
              # path, which never re-runs ksmbd_tcp_set_interfaces: the
              # interface list and its listening sockets stay whatever the
              # previous generation asked for. A newly added interface
              # therefore never gets a listener, no matter how often it is
              # bounced, while a removed one keeps serving.
              "/sys/class/ksmbd-control"
            ]
            ++ svcConfig.sharePaths;
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
          "d ${stateDir} 0700 root root - -"
          "d /run/ksmbd 0700 root root - -"
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
