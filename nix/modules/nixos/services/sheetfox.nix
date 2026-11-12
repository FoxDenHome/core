{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.sheetfox;
  port = 8080;
in
{
  options.foxDen.services.sheetfox = services.http.mkOptions {
    name = "SheetFox";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "sheetfox";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-sheetfox";
        # Ingest is bring-your-own-key (sent per request), so the server needs no secrets.
        # It shows X-Preferred-Username on jobs; OAuth sets it, otherwise never pass the client's.
        target =
          lib.optionalString (!svcConfig.oAuth.enable) ''
            proxy_set_header X-Preferred-Username "";
          ''
          + ''
            proxy_pass http://127.0.0.1:${toString port};
          '';
      }).config
      {
        systemd.services.sheetfox = {
          confinement.packages = [
            pkgs.sheetfox
          ];

          environment = {
            SHEETFOX_LISTEN = "127.0.0.1:${toString port}";
            SHEETFOX_DATA_DIR = "/var/lib/sheetfox";
          };

          serviceConfig = {
            DynamicUser = true;
            StateDirectory = "sheetfox";
            Type = "simple";
            ExecStart = [ (lib.getExe pkgs.sheetfox) ];
            Restart = "always";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
