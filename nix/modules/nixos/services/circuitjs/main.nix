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
      name = "CircuitJS";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "circuitjs";
        target = "root /web;";
        modules = [
          pkgs.nginxModules.njs
        ];
        extraHttpConfig =
          { ... }:
          ''
            js_import shortener from shortener.js;
          '';
        extraMainConfig =
          { ... }:
          ''
            env FOXCAVES_USERNAME;
            env FOXCAVES_API_KEY;
          '';
        extraConfig =
          { headerConfig, ... }:
          ''
            location ~ \.cache\. {
              ${headerConfig}
              add_header Cache-Control "public, max-age=31536000, immutable" always;
            }
            add_header Cache-Control "no-cache" always;

            location = / {
              return 307 $scheme://$http_host/circuitjs.html;
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
