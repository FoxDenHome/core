{
  pkgs,
  lib,
  foxDenLib,
  config,
  nixpkgs-unstable,
  systemArch,
  ...
}:
let
  services = foxDenLib.services;
  packages = with pkgs; [
    bash
    config.programs.ssh.package
    coreutils
    curl
    fish
    git
    gnugrep
    gnused
    gnutar
    go
    nix
    nodejs_24
    python312
    python313
    python314
    uv
    wget
  ];

  svcConfig = config.foxDen.services.renovate;
in
{
  options.foxDen.services.renovate = services.mkOptions {
    svcName = "renovate";
    name = "Renovate bot service";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "renovate";
        inherit svcConfig pkgs config;
      }).config
      {
        services.renovate = {
          enable = true;
          schedule = "*:0/5";
          package = nixpkgs-unstable.outputs.legacyPackages.${systemArch}.renovate;
          runtimePackages = packages;
          settings = {
            endpoint = "https://git.foxden.network";
            gitAuthor = "Renovate <renovate@foxden.network>";
            platform = "forgejo";
            autodiscover = true;
            onboarding = true;
            allowedCommands = [
              "^/tools/"
            ];
            autodiscoverFilter = [
              "Doridian/*"
              "foxCaves/*"
              "FoxDen/*"
              "SpaceAge/*"
            ];
          };
        };

        sops.secrets."renovate-env" = config.lib.foxDen.sops.mkIfAvailable { };

        systemd.services.renovate = {
          confinement.packages = packages;
          serviceConfig = {
            Restart = "no";
            BindReadOnlyPaths = [
              "${./renovate-tools}:/tools"
              # TODO: config.services.renovate.environment in 25.11
              config.systemd.services.renovate.environment.RENOVATE_CONFIG_FILE
              "/usr/bin/env"
            ];
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable [
              config.lib.foxDen.sops.mkGithubTokenPath
              config.sops.secrets."renovate-env".path
            ];
          };
        };
      }
    ]
  );
}
