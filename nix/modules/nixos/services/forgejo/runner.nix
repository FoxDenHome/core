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
    gnugrep
    gnused
    gnutar
    podman
    shadow
  ];

  services = foxDenLib.services;

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
      ProtectControlGroups = "private"; # Otherwise cgroups for limits don't work
      User = "forgejo-runner";
      Group = "forgejo-runner";
      WorkingDirectory = "/var/lib/forgejo-runner";
      StateDirectory = "forgejo-runner";
    };
  };

  svcConfig = config.foxDen.services.forgejo-runner;
in
{
  options.foxDen.services.forgejo-runner = services.mkOptions {
    svcName = "forgejo-runner";
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
        devices = [
          "/dev/net/tun"
          "/dev/fuse"
        ];
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "podman-forgejo-runner-prune";
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
          wants = [ "podman-forgejo-runner.service" ];

          serviceConfig = {
            ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /config.yml";
            ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
            ExecStartPre = [
              "-${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner"
              "${pkgs.coreutils}/bin/cp --update=all /registration.json /var/lib/forgejo-runner/.runner"
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
              "${./runner-config.yml}:/config.yml"
              "${config.sops.secrets."forgejo-runner-registration".path}:/registration.json"
            ];
            PrivateTmp = true;
            User = "forgejo-runner";
            Group = "forgejo-runner";
            WorkingDirectory = "/var/lib/forgejo-runner";
            StateDirectory = "forgejo-runner";
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
              ExecStart = "${pkgs.podman}/bin/podman system prune --all --force --volumes --filter until=${builtins.toString (7 * 24)}h";
              Restart = "no";
              RemainAfterExit = false;
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
              ExecStartPre = [ "${pkgs.podman}/bin/podman --log-level=info system migrate" ];
              ExecStart = "${pkgs.podman}/bin/podman --log-level=info system service --time=0 unix:///var/lib/forgejo-runner/podman.sock";
            };

            wantedBy = [ "multi-user.target" ];
          }
        ];

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
