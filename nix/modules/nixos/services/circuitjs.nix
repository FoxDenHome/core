{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.circuitjs;
in
{
  options.foxDen.services.circuitjs = (
    services.http.mkOptions {
      svcName = "circuitjs";
      name = "CircuitJS";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "circuitjs";
        target = "root /web;";
        extraConfig =
          { ... }:
          ''
            location = / {
              return 307 /circuitjs.html;
            }
          '';
      }).config
      {
        systemd.services.circuitjs = {
          serviceConfig = {
            BindReadOnlyPaths = [
              "${pkgs.circuitjs}:/web"
            ];
          };
        };
      }
    ]
  );
}
