{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.doridian-website;
in
{
  options.foxDen.services.doridian-website = (
    services.http.mkOptions {
      svcName = "doridian-website";
      name = "Doridian's website";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "doridian-website";
        target = ''
          root /web;
          index index.htm index.html;
        '';
      }).config
      {
        systemd.services.doridian-website = {
          serviceConfig = {
            BindReadOnlyPaths = [
              "${pkgs.doridian-website}:/web"
            ];
          };
        };
      }
    ]
  );
}
