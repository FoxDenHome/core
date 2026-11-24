{
  foxDenLib,
  pkgs,
  lib,
  config,
  hostName,
  ...
}:
let
  services = foxDenLib.services;
  enabledRunners = lib.filterAttrs (_: cfg: cfg.enable) config.foxDen.services.github-runners;

  packages = with pkgs; [
    bash
    catatonit
    cni-plugins
    coreutils
    findutils
    podman
    shadow
  ];

  runnerArch =
    {
      x86_64-linux = "x64";
      aarch64-linux = "arm64";
    }
    .${pkgs.stdenv.hostPlatform.system};

  # Runs in the job image (FoxDen/runner-image) as its `runner` user, which
  # has passwordless sudo and real Docker via start-docker. The image has no
  # actions runner, so this fetches the latest release into a cache shared by
  # all instances. GitHub stops giving jobs to outdated runners anyway.
  entrypoint = pkgs.writeText "github-runner-entrypoint.sh" ''
    set -euo pipefail

    # Docker in a cgroup namespace: runc enables every controller in the root's
    # subtree_control, but the kernel refuses domain ones (memory, io) while the
    # root holds processes and accepts only the threaded ones. That turns the root
    # into a threaded domain and every --memory container fails with "cannot enter
    # cgroupv2 /sys/fs/cgroup/docker ... it is in an invalid state". Move everything
    # into /init first, like docker:dind's entrypoint does.
    sudo sh -c '
      mkdir -p /sys/fs/cgroup/init
      for _ in 1 2 3 4 5; do
        xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :
        sed -e "s/ / +/g" -e "s/^/+/" < /sys/fs/cgroup/cgroup.controllers \
          > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null && exit 0
      done
      echo "Could not enable cgroup controllers for nested containers" >&2
    '

    start-docker

    cache=/cache
    version="$(curl -fsSI https://github.com/actions/runner/releases/latest \
      | tr -d '\r' | sed -n 's|^location: .*/tag/v\([0-9.]*\)$|\1|Ip' || true)"
    if [ -n "$version" ]; then
      tarball="$cache/actions-runner-linux-${runnerArch}-$version.tar.gz"
      if [ ! -f "$tarball" ]; then
        curl -fsSL -o "$tarball.$HOSTNAME" \
          "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-${runnerArch}-$version.tar.gz"
        mv "$tarball.$HOSTNAME" "$tarball"
      fi
      find "$cache" -maxdepth 1 -name 'actions-runner-*' ! -name "''${tarball##*/}" -mmin +60 -delete || true
    else
      echo 'Could not look up the latest actions runner, using the newest cached one'
      tarball="$(ls -1t "$cache"/actions-runner-linux-${runnerArch}-*.tar.gz | head -n1)"
    fi

    mkdir -p "$HOME/actions-runner"
    cd "$HOME/actions-runner"
    tar -xzf "$tarball"

    if ! ldconfig -p | grep -q libicuuc; then
      export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
    fi

    token="$(sudo cat /run/github-runner-token)"
    args=(
      --unattended
      --replace
      --url "$RUNNER_URL"
      --name "$RUNNER_NAME"
      --work _work
    )
    if [[ "$token" == ghp_* || "$token" == github_pat_* ]]; then
      args+=(--pat "$token")
    else
      args+=(--token "$token")
    fi
    unset token
    if [ -n "''${RUNNER_LABELS:-}" ]; then
      args+=(--labels "$RUNNER_LABELS")
    fi
    if [ -n "''${RUNNER_GROUP:-}" ]; then
      args+=(--runnergroup "$RUNNER_GROUP")
    fi
    if [ "''${RUNNER_EPHEMERAL:-}" = 1 ]; then
      args+=(--ephemeral)
    fi

    ./config.sh "''${args[@]}"
    unset args RUNNER_URL RUNNER_NAME RUNNER_LABELS RUNNER_GROUP RUNNER_EPHEMERAL
    exec ./run.sh
  '';

  # /etc/containers entries are symlinks into /etc/static, which confinement hides,
  # so bind each one from its store path. Follows the nixpkgs layout (*.conf.d etc.).
  containersEtcBinds = lib.mapAttrsToList (_: entry: "${entry.source}:/etc/${entry.target}") (
    lib.filterAttrs (
      name: entry: entry.enable && lib.hasPrefix "containers/" name
    ) config.environment.etc
  );

  userName = name: "github-runner-${name}";
  stateDir = name: "/var/lib/${userName name}";
  podmanUrl = name: "unix://${stateDir name}/podman.sock";
  podmanRemote = name: "${pkgs.podman}/bin/podman --url ${podmanUrl name}";

  # Same unit names as upstream's github-runner module used before:
  # bare for count == 1, else suffixed -<n>.
  instances =
    name: cfg:
    if cfg.count == 1 then
      [
        {
          unit = "github-runner-${name}";
          runnerName = "${hostName}-${name}";
        }
      ]
    else
      map (n: {
        unit = "github-runner-${name}-${toString n}";
        runnerName = "${hostName}-${name}-${toString n}";
      }) (lib.range 1 cfg.count);

  commonServiceConfig = name: {
    User = userName name;
    Group = userName name;
    WorkingDirectory = stateDir name;
    # The cache comes from StateDirectory, not tmpfiles: stateDir is an
    # impermanence bind mount that hides anything tmpfiles made beneath it.
    StateDirectory = [
      (userName name)
      "${userName name}/cache"
    ];
    PrivateTmp = true;
    Nice = 5;
  };

  # Rootless podman, set up like the Forgejo runner's (forgejo/runner.nix).
  podmanServiceBase = name: {
    confinement.packages = packages;
    path = [ "/run/wrappers" ] ++ packages;

    after = [ "network.target" ];
    wants = [ "network.target" ];

    serviceConfig = commonServiceConfig name // {
      Delegate = "cpu cpuset io memory pids";
      BindPaths = [
        "/run/user-podman-${userName name}:/run/user"
      ];
      BindReadOnlyPaths = containersEtcBinds ++ [
        "/run/wrappers/bin/newgidmap"
        "/run/wrappers/bin/newuidmap"
        "/usr/bin/env"
        # Bound into the runner containers
        "${entrypoint}:/entrypoint.sh"
      ];
      PrivateUsers = false; # Podman rootless need subuid/subgid
      ProtectKernelTunables = false; # Otherwise podman can't remount /proc
      ProtectHostname = lib.mkOverride 30 false; # See above (uses mkForce, so we need even lower priority)
      ProtectControlGroups = "private"; # Otherwise cgroups for limits don't work

      # memfd_create yields ENOENT under qemu-binfmt in d-in-d; block it.
      # Only alpine 3.23's apk uses it, and it falls back gracefully.
      SystemCallFilter = [ "~memfd_create" ];
      SystemCallErrorNumber = "EPERM";
    };
  };
in
{
  options.foxDen.services.github-runners = lib.mkOption {
    default = { };
    description = ''
      GitHub Actions runners. Each instance runs the actions runner inside a
      privileged rootless podman container of `image`, so jobs get real Docker
      like the Forgejo runner's jobs do. A rootless podman API service per entry
      runs the containers, and each instance is a unit driving one of them.
      Each entry reads its token (registration token or PAT) from the sops
      secret `github-runner-<name>`.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            example = "https://github.com/ConventionCatCorp";
            description = "Org or repo URL the runners register with.";
          };
          count = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1;
            description = "Number of runner instances (each runs one job at a time).";
          };
          image = lib.mkOption {
            type = lib.types.str;
            default = "git.foxden.network/foxden/runner-image:ubuntu-26.04";
            description = ''
              Image the runner and its jobs run in. Like FoxDen/runner-image, it must
              have bash, curl, tar, passwordless sudo for its user and `start-docker`.
            '';
          };
          extraLabels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          runnerGroup = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          ephemeral = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Start a fresh container and re-register after every job.";
          };
          extraEnvironment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Extra environment variables for the runner and its jobs.";
          };
        }
        // services.mkOptions {
          name = "GitHub Actions runner";
        };
      }
    );
  };

  # Top-level keys must not depend on config, so each is built separately.
  config = {
    sops.secrets = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "github-runner-${name}" {
        owner = userName name;
        group = userName name;
        mode = "0400";
        # The podman service copies it at start (LoadCredential)
        restartUnits = [ "podman-${userName name}.service" ];
      }
    ) enabledRunners;

    users.users = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (userName name) {
        isSystemUser = true;
        group = userName name;
        description = "GitHub Actions runner user";
        autoSubUidGidRange = true;
        home = stateDir name;
      }
    ) enabledRunners;

    users.groups = lib.mapAttrs' (name: _: lib.nameValuePair (userName name) { }) enabledRunners;

    boot.kernelModules = lib.mkIf (enabledRunners != { }) [
      "fuse"
      "tun"
      "tap"
    ];

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      name: _: "d /run/user-podman-${userName name} 0700 ${userName name} ${userName name}"
    ) enabledRunners;

    environment.persistence = lib.mkIf (enabledRunners != { }) {
      "/nix/persist/github-runner" = {
        hideMounts = true;
        directories = lib.mapAttrsToList (name: _: {
          directory = stateDir name;
          user = userName name;
          group = userName name;
          mode = "u=rwx,g=,o=";
        }) enabledRunners;
      };
    };

    systemd.timers = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "podman-${userName name}-prune" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          RandomizedDelaySec = "6h";
          Persistent = true;
        };
      }
    ) enabledRunners;

    # services.make only defines systemd.services.<unit>, so merge just that.
    systemd.services = lib.mkMerge (
      lib.flatten (
        lib.mapAttrsToList (
          name: cfg:
          let
            make =
              unit: extra:
              (services.make (
                {
                  name = unit;
                  svcConfig = cfg;
                  inherit pkgs config;
                }
                // extra
              )).config.systemd.services;
            podmanUnit = "podman-${userName name}";
            podmanDeps = [ "${podmanUnit}.service" ];

            mkInstance =
              inst:
              let
                env = {
                  RUNNER_URL = cfg.url;
                  RUNNER_NAME = inst.runnerName;
                  RUNNER_LABELS = lib.concatStringsSep "," cfg.extraLabels;
                  RUNNER_GROUP = if cfg.runnerGroup == null then "" else cfg.runnerGroup;
                  RUNNER_EPHEMERAL = if cfg.ephemeral then "1" else "0";
                }
                // cfg.extraEnvironment;
                runArgs = [
                  "run"
                  "--rm"
                  "--replace"
                  "--name=${inst.unit}"
                  "--hostname=${inst.unit}"
                  "--pull=newer"
                  "--privileged"
                  # Paths as seen by the podman service
                  "--volume=${stateDir name}/cache:/cache:U"
                  "--volume=/run/credentials/${podmanUnit}.service/token:/run/github-runner-token:ro"
                  "--volume=/entrypoint.sh:/entrypoint.sh:ro"
                ]
                ++ foxDenLib.services.oci.options
                ++ lib.mapAttrsToList (k: v: "--env=${k}=${v}") env
                ++ [
                  cfg.image
                  "/entrypoint.sh"
                ];
              in
              [
                (make inst.unit { })
                {
                  ${inst.unit} = {
                    after = podmanDeps;
                    requires = podmanDeps;
                    # Restarting podman kills the runner containers
                    partOf = podmanDeps;

                    serviceConfig = commonServiceConfig name // {
                      ExecStart = "${podmanRemote name} ${lib.escapeShellArgs runArgs}";
                      ExecStopPost = "-${podmanRemote name} rm --force --ignore --time 30 ${inst.unit}";
                      # Ephemeral runners exit after every job, and NRestarts never resets
                      # on auto-restarts, so services.make's backoff would climb to 5m
                      # between jobs. Beat its mkForce.
                      RestartSteps = lib.mkIf cfg.ephemeral (lib.mkOverride 40 0);
                      TimeoutStopSec = "60s";
                    };

                    wantedBy = [ "multi-user.target" ];
                  };
                }
              ];
          in
          [
            (make podmanUnit {
              devices = [
                "/dev/net/tun"
                "/dev/fuse"
              ];
            })
            (make "${podmanUnit}-prune" { })
            {
              ${podmanUnit} = lib.mkMerge [
                (podmanServiceBase name)
                {
                  serviceConfig = {
                    Type = "exec";
                    # A copy, not a bind: sops-nix replaces /run/secrets.d on every
                    # activation, which would drop a bind of the secret file and break
                    # every runner container started after a deploy.
                    LoadCredential = "token:${config.sops.secrets."github-runner-${name}".path}";
                    ExecStartPre = [
                      # Runtime state outlives the service's netns; start as if after a reboot.
                      "-${pkgs.findutils}/bin/find /run/user -mindepth 1 -delete"
                      "${pkgs.podman}/bin/podman --log-level=info system migrate"
                      "-${pkgs.podman}/bin/podman container prune --force"
                    ];
                    ExecStart = "${pkgs.podman}/bin/podman --log-level=info system service --time=0 ${podmanUrl name}";
                    ExecStop = "${pkgs.podman}/bin/podman stop --all --time 30";
                    TimeoutStopSec = "60s";
                  };
                  wantedBy = [ "multi-user.target" ];
                }
              ];

              "${podmanUnit}-prune" = lib.mkMerge [
                (podmanServiceBase name)
                {
                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = "${pkgs.podman}/bin/podman system prune --all --force --volumes --filter until=${toString (7 * 24)}h";
                    Restart = "no";
                    RemainAfterExit = false;
                  };
                }
              ];
            }
          ]
          ++ lib.concatMap mkInstance (instances name cfg)
        ) enabledRunners
      )
    );
  };
}
