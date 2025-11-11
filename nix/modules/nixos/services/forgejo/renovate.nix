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
          schedule = "hourly";
          package = nixpkgs-unstable.outputs.legacyPackages.${systemArch}.renovate;
          runtimePackages = packages;
          settings = {
            endpoint = "https://git.foxden.network";
            gitAuthor = "Renovate <renovate@foxden.network>";
            platform = "forgejo";
            autodiscover = true;
            onboardingConfigFileName = ".forgejo/renovate.json";
            configFileNames = [ ".forgejo/renovate.json" ];
          };
        };

        sops.secrets."renovate-env" = config.lib.foxDen.sops.mkIfAvailable { };

        systemd.services.renovate = {
          confinement.packages = packages;
          serviceConfig = {
            Restart = "no";
            BindReadOnlyPaths = [
              # TODO: config.services.renovate.environment in 25.11
              config.systemd.services.renovate.environment.RENOVATE_CONFIG_FILE
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
