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

  thumbnailerListen = "127.0.0.1:4190";
  vipsBin = lib.getBin pkgs.vips;
  ffmpegBin = lib.getBin pkgs.ffmpeg-headless;
  thumbnailer = pkgs.writers.writePython3Bin "nasweb-thumbnailer" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./nasweb-thumbnailer.py);
in
{
  options.foxDen.services.nasweb = {
    root = lib.mkOption {
      type = lib.types.path;
      description = "Root directory to serve files from";
    };
  }
  // (services.http.mkOptions {
    name = "NAS web interface";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make rec {
        inherit svcConfig pkgs config;
        name = "nasweb";
        modules = [
          pkgs.nginxModules.njs
        ];
        target = ''
          include ${pkgs.foxden-jsindex}/lib/node_modules/foxden-jsindex/nginx-location.conf;
          include ${pkgs.foxden-jsindex}/lib/node_modules/foxden-jsindex/shares-location.conf;
          if ($arg_thumb != "") {
            js_content files.thumb;
          }
        '';
        extraHttpConfig =
          { ... }:
          ''
            # Persisted so share links (and their revocations) survive restarts
            js_shared_dict_zone zone=state:1m state=/var/lib/foxden/nasweb/state.json;
            js_shared_dict_zone zone=shares_revocations:1m timeout=30d state=/var/lib/foxden/nasweb/shares_revocations.json;
            js_shared_dict_zone zone=render_cache:1m;
            js_import files from files.js;
            js_import shares from shares.js;
          '';
        extraConfig =
          { ... }:
          ''
            set $jsindex_ignore "/tmp";
            set $jsindex_header "/njs/templates/custom/nasweb_header.html";
            set $jsindex_entry "/njs/templates/entry.html";
            set $jsindex_footer "/njs/templates/footer.html";
            set $jsindex_grid "true";
            set $jsindex_thumbs "true";

            root /data;

            location /pub/ {
              satisfy any;
              allow 0.0.0.0/0;
              allow ::0/0;
              ${target}
            }

            include ${pkgs.foxden-jsindex}/lib/node_modules/foxden-jsindex/nginx.conf;
            include ${pkgs.foxden-jsindex}/lib/node_modules/foxden-jsindex/shares.conf;

            # njs (files.thumb / shares.view) checks access, then redirects here
            location ^~ /_jsindex-static/_thumb/ {
              internal;
              proxy_pass http://${thumbnailerListen};
              proxy_read_timeout 300s;
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
      (services.mkNamed "nasweb-thumbnailer" { inherit svcConfig pkgs config; }).config
      {
        systemd.services.nasweb-thumbnailer = {
          confinement.packages = [
            vipsBin
            ffmpegBin
          ];

          environment = {
            THUMB_ROOT = "/data";
            LISTEN = thumbnailerListen;
            VIPSTHUMBNAIL = "${vipsBin}/bin/vipsthumbnail";
            FFMPEG = "${ffmpegBin}/bin/ffmpeg";
          };

          serviceConfig = {
            DynamicUser = true;
            # Persisted (/var/cache/private), the cache prunes entries unused for 90 days
            CacheDirectory = "foxden/nasweb-thumbnailer";
            BindReadOnlyPaths = [
              "${svcConfig.root}:/data"
            ];
            ExecStart = "${thumbnailer}/bin/nasweb-thumbnailer";
            Nice = 10;
            IOSchedulingClass = "best-effort";
            IOSchedulingPriority = 7;
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
