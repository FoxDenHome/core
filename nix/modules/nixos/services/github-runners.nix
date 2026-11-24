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

  # Unit names upstream's github-runner/service.nix creates for an entry
  # (we don't use its `orgs` fan-out): bare for count == 1, else suffixed -<n>.
  unitNames =
    name: cfg:
    if cfg.count == 1 then
      [ "github-runner-${name}" ]
    else
      map (n: "github-runner-${name}-${toString n}") (lib.range 1 cfg.count);
in
{
  options.foxDen.services.github-runners = lib.mkOption {
    default = { };
    description = ''
      GitHub Actions runners, built on nixpkgs' `services.github-runners`
      and run through `services.make` (own netns, confinement).
      Each entry reads its token from the sops secret `github-runner-<name>`.
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
            description = "Re-register with a clean state after every job.";
          };
          extraPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Packages on PATH and inside the confinement chroot for jobs.";
          };
          serviceOverrides = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = "Passed through to upstream's serviceOverrides.";
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
      name: _: lib.nameValuePair "github-runner-${name}" { }
    ) enabledRunners;

    services.github-runners = lib.mapAttrs (name: cfg: {
      enable = true;
      inherit (cfg)
        url
        count
        extraLabels
        runnerGroup
        ephemeral
        ;
      name = "${hostName}-${name}";
      tokenFile = config.sops.secrets."github-runner-${name}".path;
      replace = true;
      extraPackages =
        (with pkgs; [
          curl
          findutils
          gawk
          gnugrep
          gnused
          jq
          unzip
          xz
          zstd
        ])
        ++ cfg.extraPackages;

      serviceOverrides = lib.mkMerge [
        {
          # Upstream sets Restart=no (or on-success when ephemeral);
          # match the other foxDen services instead.
          Restart = lib.mkForce "always";
          # Ephemeral runners exit after every job, and NRestarts never resets
          # on auto-restarts, so services.make's backoff would climb to 5m
          # between jobs. Beat its mkForce.
          RestartSteps = lib.mkIf cfg.ephemeral (lib.mkOverride 40 0);
          # Scripts commonly use #!/usr/bin/env
          BindReadOnlyPaths = [ "/usr/bin/env" ];
        }
        cfg.serviceOverrides
      ];
    }) enabledRunners;

    # services.make only defines systemd.services.<unit>, so merge just that.
    systemd.services = lib.mkMerge (
      lib.flatten (
        lib.mapAttrsToList (
          name: cfg:
          map (
            unit:
            (services.make {
              name = unit;
              svcConfig = cfg;
              inherit pkgs config;
            }).config.systemd.services
          ) (unitNames name cfg)
        ) enabledRunners
      )
    );
  };
}
