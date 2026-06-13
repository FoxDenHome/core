{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.homebridge;
in
{
  options.foxDen.services.homebridge = services.http.mkOptions {
    name = "HomeBridge";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-homebridge";
        target = "proxy_pass http://127.0.0.1:${toString config.services.homebridge.uiSettings.port};";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "homebridge";
      }).config
      {
        services.homebridge = {
          enable = true;
          settings = {
            bridge.name = "FoxDen HomeBridge";
          };
        };

        environment.persistence."/nix/persist/homebridge" = {
          hideMounts = true;
          directories = [
            "/var/lib/homebridge"
          ];
        };
      }
    ]
  );
}
