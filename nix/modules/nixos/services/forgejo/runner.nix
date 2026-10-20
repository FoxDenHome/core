{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  packages = with pkgs; [
    bash
    catatonit
    cni-plugins
    coreutils
    findutils
    git
    gnugrep
    gnused
    gnutar
    podman
    shadow
  ];

  services = foxDenLib.services;
  svcConfig = config.foxDen.services.forgejo-runner;
  containerHost = foxDenLib.hosts.getByName config svcConfig.containerHost;

  suffixes = [ "" ] ++ map (label: "-${label}") svcConfig.labels;
  images = [
    "ubuntu-24.04"
    "ubuntu-26.04"
  ];

  mkDir = (
    dir: {
      directory = dir;
      user = "forgejo-runner";
      group = "forgejo-runner";
      mode = "u=rwx,g=,o=";
    }
  );

  podmanServiceBase = {
    confinement.packages = packages;
    path = [ "/run/wrappers" ] ++ packages;

    after = [ "network.target" ];
    wants = [ "network.target" ];

    serviceConfig = {
      Delegate = "cpu cpuset io memory pids";
      BindPaths = [
        "/run/user-podman-forgejo-runner:/run/user"
      ];
      BindReadOnlyPaths = [
        "/etc/containers/containers.conf"
        "/etc/containers/policy.json"
        "/etc/containers/registries.conf"
        "/etc/containers/storage.conf"
        "/run/wrappers/bin/newgidmap"
        "/run/wrappers/bin/newuidmap"
        "/usr/bin/env"
      ];
      PrivateTmp = true;
      PrivateUsers = false; # Podman rootless need subuid/subgid
      ProtectKernelTunables = false; # Otherwise podman can't remount /proc
      ProtectHostname = lib.mkOverride 30 false; # See above (uses mkForce, so we need even lower priority)
      ProtectControlGroups = "private"; # Otherwise cgroups for limits don't work
      User = "forgejo-runner";
      Group = "forgejo-runner";
      WorkingDirectory = "/var/lib/forgejo-runner";
      StateDirectory = "forgejo-runner";

      # memfd_create yields ENOENT under qemu-binfmt in d-in-d; block it.
      # Only alpine 3.23's apk uses it, and it falls back gracefully.
      SystemCallFilter = [ "~memfd_create" ];
      SystemCallErrorNumber = "EPERM";
    };
  };

  runnerConfigYaml = {
    log = {
      level = "info";
      job_level = "info";
    };
    runner = {
      file = ".runner";
      capacity = svcConfig.capacity;
      envs = { };
      env_file = ".env";
      timeout = "3h";
      shutdown_timeout = "3h";
      insecure = false;
      fetch_timeout = "5s";
      fetch_interval = "2s";
      report_interval = "1s";
      labels = builtins.concatLists (
        map (
          suffix:
          map (image: "${image}${suffix}:docker://git.foxden.network/foxden/runner-image:${image}") images
        ) suffixes
      );
    };
    cache = {
      enabled = true;
      port = 0;
      dir = "";
      external_server = "";
      secret = "";
      host = "";
      proxy_port = 0;
      actions_cache_url_override = "";
    };
    container = {
      network = "";
      enable_ipv6 = true;
      privileged = true;
      options = "--add-host=host.docker.internal:host-gateway";
      workdir_parent = "";
      valid_volumes = [ ];
      docker_host = "-";
      force_pull = true;
      force_rebuild = false;
    };
    host = {
      workdir_parent = "";
    };
  };
in
{
  options.foxDen.services.forgejo-runner = {
    containerHost = lib.mkOption {
      type = lib.types.str;
    };
    capacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "The capacity of concurrent jobs the runner can handle.";
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      defaultText = "[ ]";
      description = "The extra sub label(s) to use for the runner.";
    };
  }
  // services.mkOptions {
    name = "Forgejo runner server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "forgejo-runner";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "podman-forgejo-runner";
        overrideHost = svcConfig.containerHost;
        devices = [
          "/dev/net/tun"
          "/dev/fuse"
        ];
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "podman-forgejo-runner-prune";
        overrideHost = svcConfig.containerHost;
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "harmonia";
        overrideHost = svcConfig.containerHost;
        inherit svcConfig pkgs config;
      }).config
      {
        users.users.forgejo-runner = {
          isSystemUser = true;
          group = "forgejo-runner";
          description = "Forgejo runner user";
          autoSubUidGidRange = true;
          home = "/var/lib/forgejo-runner";
        };
        users.groups.forgejo-runner = { };

        boot.kernelModules = [
          "fuse"
          "tun"
          "tap"
        ];

        sops.secrets."forgejo-runner-registration" = {
          owner = "forgejo-runner";
          group = "forgejo-runner";
          mode = "0400";
        };

        systemd.services.forgejo-runner = {
          confinement.packages = packages;
          path = packages;

          after = [ "podman-forgejo-runner.service" ];
          requires = [ "podman-forgejo-runner.service" ];

          serviceConfig = {
            ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /var/lib/forgejo-runner/config.yml";
            ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
            ExecStartPre = [
              "-${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner /var/lib/forgejo-runner/config.yml"
              "${pkgs.coreutils}/bin/cp --update=all /registration.json /var/lib/forgejo-runner/.runner"
              "${pkgs.coreutils}/bin/cp --update=all /config.yml /var/lib/forgejo-runner/config.yml"
              "${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner"
            ];
            Environment = [
              "DOCKER_HOST=unix:///var/lib/forgejo-runner/podman.sock"
            ];
            BindReadOnlyPaths = [
              "/etc/containers/containers.conf"
              "/etc/containers/policy.json"
              "/etc/containers/registries.conf"
              "/etc/containers/storage.conf"
              "/usr/bin/env"
              "${pkgs.writers.writeYAML "config.yml" runnerConfigYaml}:/config.yml"
              "${config.sops.secrets."forgejo-runner-registration".path}:/registration.json"
            ];
            PrivateTmp = true;
            User = "forgejo-runner";
            Group = "forgejo-runner";
            WorkingDirectory = "/var/lib/forgejo-runner";
            StateDirectory = "forgejo-runner";
            Nice = 5;
            TimeoutStopSec = "15s";
          };

          wantedBy = [ "multi-user.target" ];
        };

        systemd.tmpfiles.rules = [
          "d /run/user-podman-forgejo-runner 0700 forgejo-runner forgejo-runner"
        ];

        systemd.services.podman-forgejo-runner-prune = lib.mkMerge [
          podmanServiceBase
          {
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.podman}/bin/podman system prune --all --force --volumes --filter until=${toString (7 * 24)}h";
              Restart = "no";
              RemainAfterExit = false;
              Nice = 5;
            };
          }
        ];

        systemd.timers.podman-forgejo-runner-prune = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "weekly";
            RandomizedDelaySec = "6h";
            Persistent = true;
          };
        };

        systemd.services.podman-forgejo-runner = lib.mkMerge [
          podmanServiceBase
          {
            serviceConfig = {
              Type = "exec";
              ExecStartPre = [
                # Runtime state outlives the service's netns, so stale
                # aardvark-dns configs break DNS after a restart. Wiping it
                # makes podman refresh as if after a reboot.
                "-${pkgs.findutils}/bin/find /run/user -mindepth 1 -delete"
                "${pkgs.podman}/bin/podman --log-level=info system migrate"
                "-${pkgs.podman}/bin/podman container prune --force"
                "-${pkgs.podman}/bin/podman network prune --force"
              ];
              ExecStart = "${pkgs.podman}/bin/podman --log-level=info system service --time=0 unix:///var/lib/forgejo-runner/podman.sock";
              ExecStop = "${pkgs.podman}/bin/podman stop --all --time 30";
              Nice = 5;
              TimeoutStopSec = "60s";
            };

            # Restarting the runner orphans its job containers and networks
            partOf = [ "forgejo-runner.service" ];

            wantedBy = [ "multi-user.target" ];
          }
        ];

        # Local substituter for job containers (host.docker.internal:1111)
        services.harmonia.cache = {
          enable = true;
          settings = {
            bind = "[::]:1111";
            priority = 30; # Ahead of cache.nixos.org (40)
          };
        };
        nix.settings.allowed-users = [ "harmonia" ];
        systemd.services.harmonia.serviceConfig = {
          BindReadOnlyPaths = [
            "/nix/store"
            "/nix/var/nix"
          ];
          PrivateNetwork = lib.mkForce false; # Joins the container netns via services.make instead
          Nice = 5;
        };
        # Harmonia is socket-activated, so only the listener needs the containers' netns
        systemd.sockets.harmonia = {
          requires = [ containerHost.unit ];
          bindsTo = [ containerHost.unit ];
          after = [ containerHost.unit ];
          socketConfig.NetworkNamespacePath = containerHost.namespacePath;
        };

        environment.persistence."/nix/persist/forgejo" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/forgejo-runner")
          ];
        };
      }
    ]
  );
}
