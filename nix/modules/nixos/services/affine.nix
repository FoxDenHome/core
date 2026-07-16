{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.affine;
in
{
  options.foxDen.services.affine = services.http.mkOptions {
    name = "AFFiNE";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-affine";
        target = "proxy_pass http://127.0.0.1:3010;";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "affine";
      }).config
      {
        foxDen.services.postgresql = {
          enable = true;
          services = [
            {
              database = "affine";
              service = "affine";
            }
          ];
        };

        systemd.services.affine = {
          serviceConfig = {
            DynamicUser = true;
            StateDirectory = "affine";
            User = "affine";
            Group = "affine";
            Environment = [
              "UPLOAD_LOCATION=/var/lib/affine/data"
              "CONFIG_LOCATION=/var/lib/affine/config"
              "\"DATABASE_URL=postgresql://affine@${
                lib.replaceString "/" "%2F" config.foxDen.services.postgresql.socketPath
              }/affine\""
              "AFFINE_INDEXER_ENABLED=false"
            ];
            ExecStart = [ "${pkgs.affine-server}/bin/affine" ];
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
