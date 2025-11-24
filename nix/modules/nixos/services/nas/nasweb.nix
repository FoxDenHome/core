{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.nasweb;
in
{
  options.foxDen.services.nasweb = {
    root = lib.mkOption {
      type = lib.types.path;
      description = "Root directory to serve files from";
    };
  }
  // (services.http.mkOptions {
    svcName = "nasweb";
    name = "NAS web interface";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "nasweb";
        modules = [
          pkgs.nginxModules.njs
        ];
        target = ''
          root /data;
          set $jsindex_ignore "";
          set $jsindex_header "/njs/templates/custom/nasweb_header.html";
          set $jsindex_entry "/njs/templates/entry.html";
          set $jsindex_footer "/njs/templates/footer.html";
        '';
        extraConfig =
          { defaultTarget, ... }:
          ''
            js_shared_dict_zone zone=render_cache:1m;
            js_import files from files.js;

            location ~ ^/guest/.*[^/]$ {
              satisfy any;
              allow 0.0.0.0/0;
              allow ::0/0;
              root /nas;
              autoindex off;
            }
          '';
      }).config
      {
        systemd.services.nasweb = {
          confinement.packages = [
            pkgs.foxden-jsindex
          ];

          serviceConfig = {
            BindReadOnlyPaths = [
              "${pkgs.foxden-jsindex}/lib/node_modules/foxden-jsindex:/njs"
              "${./templates}:/njs/templates/custom"
              "${svcConfig.root}:/data"
            ];
          };
        };
      }
    ]
  );
}
