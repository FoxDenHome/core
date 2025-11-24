{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.mirror;
  primaryInterface = services.getPrimaryInterface config svcConfig;

  findFqdnForPrefix =
    prefix:
    lib.findFirst (
      fqdn: lib.strings.hasPrefix "${prefix}." fqdn
    ) (throw "No FQDN found for mirror service ${prefix}") primaryInterface.dns.fqdns;

  sourceType =
    with lib.types;
    submodule {
      options = {
        rsyncUrl = lib.mkOption {
          type = str;
        };
        httpsUrl = lib.mkOption {
          type = str;
          default = "";
        };
        forceSync = lib.mkOption {
          type = bool;
          default = false;
        };
      };
    };

  jsIndexConf = import ./../../packages/foxden-jsindex/config.nix { };
in
{
  options.foxDen.services.mirror = {
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mirror/data";
      description = "Directory to store mirror data";
    };
    archMirrorId = lib.mkOption {
      type = lib.types.str;
    };
    sources = lib.mkOption {
      type = lib.types.attrsOf sourceType;
    };
  }
  // (services.http.mkOptions {
    svcName = "mirror";
    name = "Mirror server";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        name = "mirror-nginx";
        dynamicUser = false;
        modules = [
          pkgs.nginxModules.njs
          pkgs.nginxModules.fancyindex
        ];
        rawConfig =
          { baseWebConfig, proxyConfigNoHost, ... }:
          ''
            js_shared_dict_zone zone=render_cache:1m;
            js_import files from files.js;
            js_var $arch_mirror_id "${svcConfig.archMirrorId}";

            server {
              server_name ${findFqdnForPrefix "mirror"};
              ${baseWebConfig}
              root /data;

              set $jsindex_ignore "/archlinux /cachyos";
              set $jsindex_header "/njs/templates/custom/mirror_header.html";
              set $jsindex_entry "/njs/templates/entry.html";
              set $jsindex_footer "/njs/templates/footer.html";

              location /archlinux/ {
                rewrite ^/archlinux/(.*)$  https://${findFqdnForPrefix "archlinux"}/$1 redirect;
              }

              location /cachyos/ {
                rewrite ^/cachyos/(.*)$  https://${findFqdnForPrefix "cachyos"}/$1 redirect;
              }

              ${jsIndexConf.nginxConfig}
            }

            server {
              server_name ${findFqdnForPrefix "archlinux"};
              ${baseWebConfig}
              root /data/archlinux;

              set $jsindex_ignore "";
              set $jsindex_header "/njs/templates/custom/archlinux_header.html";
              set $jsindex_entry "/njs/templates/entry.html";
              set $jsindex_footer "/njs/templates/footer.html";

              ${jsIndexConf.nginxConfig}
            }

            server {
              server_name ${findFqdnForPrefix "cachyos"};
              ${baseWebConfig}
              root /data/cachyos;

              location / {
                add_header X-Content-Type-Options "nosniff" always;
                add_header X-Frame-Options "DENY" always;
                add_header Strict-Transport-Security "max-age=31536000; preload; includeSubDomains" always;

                fancyindex on;
                fancyindex_exact_size off;
                fancyindex_header "/.theme/header.html";
                fancyindex_footer "/.theme/footer.html";
                fancyindex_show_path off;
              }
            }
          '';
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "mirror-rsyncd";
        inherit svcConfig pkgs config;
      }).config
      {
        users.users.mirror = {
          isSystemUser = true;
          group = "mirror";
        };
        users.groups.mirror = { };

        environment.etc."foxden/mirror/rsyncd.conf" = {
          text = ''
            use chroot = no
            max connections = 128
            pid file = /tmp/rsyncd.pid
            lock file = /tmp/rsyncd.lock
            read only = yes
            numeric ids = yes
            reverse lookup = no
            forward lookup = no

            exclude = /.dori-local /_dori-static /.well-known

            [archlinux]
                    path = /data/archlinux

            [cachyos]
                    path = /data/cachyos

            [foxdenaur]
                    path = /data/foxdenaur
          '';
        };

        systemd.services = {
          mirror-nginx = {
            confinement.packages = [
              pkgs.foxden-jsindex
            ];

            serviceConfig = {
              BindReadOnlyPaths = [
                "${pkgs.foxden-jsindex}/lib/node_modules/foxden-jsindex:/njs"
                "${./templates}:/njs/templates/custom"
                "${svcConfig.dataDir}:/data"
              ];
              User = "mirror";
              Group = "mirror";
            };
          };

          mirror-rsyncd = {
            restartTriggers = [ config.environment.etc."foxden/mirror/rsyncd.conf".text ];

            serviceConfig = {
              BindReadOnlyPaths = [
                "${svcConfig.dataDir}:/data"
              ];

              LoadCredential = "rsyncd.conf:/etc/foxden/mirror/rsyncd.conf";

              ExecStart = [
                "${pkgs.rsync}/bin/rsync --daemon --no-detach --config=\${CREDENTIALS_DIRECTORY}/rsyncd.conf"
              ];

              User = "mirror";
              Group = "mirror";

              StateDirectory = "mirror";
            };

            wantedBy = [ "multi-user.target" ];
          };
        }
        // (lib.attrsets.listToAttrs (
          map (
            { name, value }:
            let
              svcName = "mirror-sync-${name}";
            in
            {
              name = svcName;

              value = lib.mkMerge [
                {
                  confinement.packages = [
                    pkgs.bash
                    pkgs.curl
                    pkgs.rsync
                    pkgs.coreutils
                  ];

                  path = [
                    pkgs.bash
                    pkgs.curl
                    pkgs.rsync
                    pkgs.coreutils
                  ];

                  serviceConfig = {
                    Type = "simple";
                    Restart = "no";

                    User = "mirror";
                    Group = "mirror";

                    BindPaths = [
                      "${svcConfig.dataDir}/${name}:/data"
                    ];

                    Environment = [
                      "\"MIRROR_SOURCE_RSYNC=${value.rsyncUrl}\""
                      "\"MIRROR_SOURCE_HTTPS=${value.httpsUrl}\""
                      "MIRROR_FORCE_SYNC=${toString value.forceSync}"
                    ];

                    ExecStart = [
                      "${pkgs.bash}/bin/bash ${./refresh/run.sh} ${./refresh/sync.sh}"
                    ];
                  };
                }
                (services.make {
                  name = svcName;
                  inherit svcConfig pkgs config;
                }).config.systemd.services.${svcName}
              ];
            }
          ) (lib.attrsets.attrsToList svcConfig.sources)
        ));

        systemd.timers = (
          lib.attrsets.listToAttrs (
            map (
              { name, value }:
              let
                svcName = "mirror-sync-${name}";
              in
              {
                name = svcName;
                value = {
                  wantedBy = [ "timers.target" ];
                  timerConfig = {
                    OnCalendar = "hourly";
                    RandomizedDelaySec = "45m";
                    Persistent = true;
                  };
                };
              }
            ) (lib.attrsets.attrsToList svcConfig.sources)
          )
        );

        environment.persistence."/nix/persist/mirror" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/mirror/data";
              user = "mirror";
              group = "mirror";
              mode = "u=rwx,g=,o=";
            }
            {
              directory = "/var/lib/mirror";
              user = "mirror";
              group = "mirror";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
