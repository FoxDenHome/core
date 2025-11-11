{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.spaceage-website;
in
{
  options.foxDen.services.spaceage-website = (
    services.http.mkOptions {
      svcName = "spaceage-website";
      name = "SpaceAge website";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "spaceage-website";
        target = ''
          root /web;
          location / {
            index index.htm index.html;
          }
        '';
      }).config
      {
        systemd.services.spaceage-website = {
          serviceConfig = {
            BindReadOnlyPaths = [
              "${pkgs.spaceage-website}:/web"
            ];
          };
        };
      }
    ]
  );
}
