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
        extraHttpConfig =
          { ... }:
          ''
            js_import shortener from shortener.js;
          '';
        extraConfig =
          { ... }:
          ''
            location = / {
              return 307 /circuitjs.html;
            }

            location = /shorturl {
              js_content shortener.create;
            }
          '';
      }).config
      {
        sops.secrets.foxcaves-shortener = config.lib.foxDen.sops.mkIfAvailable {
          inherit (config.sops.secrets."github-token-env") sopsFile;
        };

        systemd.services.circuitjs = {
          serviceConfig = {
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.foxcaves-shortener.path;

            BindReadOnlyPaths = [
              "${pkgs.circuitjs}/share/circuitjs:/web"
              "${./shortener.js}:/njs/lib/shortener.js"
            ];
          };
        };
      }
    ]
  );
}
