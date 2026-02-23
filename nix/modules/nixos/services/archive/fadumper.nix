{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.fadumper;

  faDumperDir = "${pkgs.fadumper}/lib/node_modules/fadumper";

  defaultDataDir = "/var/lib/fadumper";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);

  hostName = services.getFirstFQDN config svcConfig;
in
{
  options.foxDen.services.fadumper = {
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = defaultDataDir;
      description = "Directory to store FADumper data";
    };
  }
  // (services.http.mkOptions {
    svcName = "fadumper";
    name = "FADumper";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "fadumper-api";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "fadumper-refresh";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-fadumper-api";
        target = "proxy_pass http://127.0.0.1:8001;";
      }).config
      {
        foxDen.services.opensearch = {
          enable = true;
          users.fadumper = {
            indexPatterns = [ "fadumper_*" ];
          };
          services = [
            "fadumper-api"
            "fadumper-refresh"
          ];
        };

        users.users.fadumper = {
          isSystemUser = true;
          description = "FADumper service user";
          group = "fadumper";
        };
        users.groups.fadumper = { };

        sops.secrets.fadumper = config.lib.foxDen.sops.mkIfAvailable { };

        systemd.services.fadumper-api = {
          confinement.packages = [ pkgs.fadumper ];

          serviceConfig = {
            BindPaths = [
              svcConfig.dataDir
            ];

            User = "fadumper";
            Group = "fadumper";

            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.fadumper.path;

            Type = "simple";
            ExecStart = [ "${pkgs.fadumper}/bin/fadumper-api" ];
            WorkingDirectory = faDumperDir;
            StateDirectory = ifDefaultData "fadumper";

            Environment = [
              "\"DOWNLOAD_PATH=${svcConfig.dataDir}\""
              "\"URL_HOST=${hostName}\""
              (if svcConfig.tls.enable then "URL_PROTOCOL=https" else "URL_PROTOCOL=http")
              "HOST=127.0.0.1"
              "PORT=8001"
            ];
          };

          wantedBy = [ "multi-user.target" ];
        };

        # systemd.services.fadumper-refresh = {
        #   confinement.packages = [ pkgs.fadumper ];
        #   path = [ pkgs.fadumper ];
        #   serviceConfig = {
        #     BindPaths = [
        #       svcConfig.dataDir
        #     ];
        #     Type = "simple";
        #     Restart = "no";
        #     User = "fadumper";
        #     Group = "fadumper";
        #     EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.fadumper.path;
        #     ExecStart = [ "${pkgs.bash}/bin/bash ${pkgs.fadumper}/lib/node_modules/fadumper/looper.sh" ];
        #     WorkingDirectory = faDumperDir;
        #     StateDirectory = ifDefaultData "fadumper";
        #     Environment = [
        #       "\"DOWNLOAD_PATH=${svcConfig.dataDir}\""
        #     ];
        #   };
        # };
        # systemd.timers.fadumper-refresh = {
        #   wantedBy = [ "timers.target" ];
        #   timerConfig = {
        #     OnCalendar = "*-*-* 2:00:00";
        #     RandomizedDelaySec = "15min";
        #     Persistent = false;
        #   };
        # };

        environment.persistence."/nix/persist/fadumper" = ifDefaultData {
          hideMounts = true;
          directories = [
            {
              directory = defaultDataDir;
              user = "fadumper";
              group = "fadumper";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
