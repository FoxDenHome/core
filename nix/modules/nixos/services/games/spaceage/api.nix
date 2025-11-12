{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.spaceage-api;
in
{
  options.foxDen.services.spaceage-api = {
  }
  // services.http.mkOptions {
    svcName = "spaceage-api";
    name = "SpaceAge API";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "spaceage-api";
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-spaceage-api";
        target = "proxy_pass http://127.0.0.1:4000;";
      }).config
      {
        sops.secrets.spaceage-api = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "spaceage-api";
          group = "spaceage-api";
        };

        users.users.spaceage-api = {
          isSystemUser = true;
          group = "spaceage-api";
        };
        users.groups.spaceage-api = { };

        systemd.services.spaceage-api = {
          serviceConfig = {
            User = "spaceage-api";
            Group = "spaceage-api";

            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.spaceage-api.path;

            Type = "exec";
            ExecStart = "${pkgs.space_age_api}/bin/space_age_api start";
            ExecStop = "${pkgs.space_age_api}/bin/space_age_api stop";
            ExecReload = "${pkgs.space_age_api}/bin/space_age_api restart";
          };

          wantedBy = [ "multi-user.target" ];
        };

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [ "spaceage_api" ];
              service = "spaceage-api";
            }
          ];
        };
      }
    ]
  );
}
