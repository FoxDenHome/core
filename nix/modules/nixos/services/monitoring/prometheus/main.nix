{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  mkDir = (
    dir: {
      directory = dir;
      user = "prometheus";
      group = "prometheus";
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.prometheus;
  hostName = services.getFirstFQDN config svcConfig;

  cfgObj = {
    global = {
      scrape_interval = "60s";
      evaluation_interval = "60s";
      external_labels = {
        monitor = hostName;
      };
    };
    scrape_config_files = [
      "/tmp/scrape_configs/*.yml"
    ];
  };
in
{
  options.foxDen.services.prometheus = services.mkOptions {
    svcName = "prometheus";
    name = "Prometheus monitoring server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "prometheus";
        inherit svcConfig pkgs config;
      }).config
      {
        services.prometheus = {
          enable = true;
          stateDir = "prometheus";
          configText = builtins.toJSON cfgObj;
        };

        sops.secrets.prometheus = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "prometheus";
          group = "prometheus";
        };

        systemd.services.prometheus = {
          confinement.packages = [
            pkgs.coreutils
          ];

          serviceConfig = {
            ExecStartPre = [
              "${pkgs.coreutils}/bin/mkdir -p /tmp/scrape_configs"
              "${pkgs.coreutils}/bin/touch /tmp/scrape_configs/prometheus-scrape.yml"
              "${pkgs.coreutils}/bin/chmod 600 /tmp/scrape_configs/prometheus-scrape.yml"
              "${pkgs.envsubst}/bin/envsubst -i ${./prometheus-scrape.yml} -o /tmp/scrape_configs/prometheus-scrape.yml"
            ];
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.prometheus.path;
          };
        };

        environment.persistence."/nix/persist/prometheus" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/prometheus")
          ];
        };
      }
    ]
  );
}
