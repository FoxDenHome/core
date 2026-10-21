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
      (services.make {
        inherit svcConfig pkgs config;
        name = "homebridge";
      }).config
      {
        services.homebridge = {
          enable = true;
          uiSettings = {
            port = 80;
          };
          settings = {
            bridge.name = "FoxDen HomeBridge";
          };
        };

        # preStart calls install/rm/ln from PATH
        systemd.services.homebridge.confinement.packages = [ pkgs.coreutils ];

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
