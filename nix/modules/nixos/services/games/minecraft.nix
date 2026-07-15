{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.minecraft;

  defaultDataDir = "/var/lib/minecraft";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);
  serverPackage = pkgs.foxden-minecraft;
in
{
  options.foxDen.services.minecraft =
    with lib.types;
    {
      dataDir = lib.mkOption {
        type = path;
        default = defaultDataDir;
        description = "Directory to store Minecraft data";
      };
    }
    // (services.http.mkOptions {
      name = "Minecraft server";
    });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "minecraft";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "minecraft-ccsftp";
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-minecraft";
        target = "return 308 $scheme://$http_host/map/;";
        extraHttpConfig =
          { ... }:
          ''
            map $uri $ae2_content_type {
               default "application/octet-stream";
               /ae2/ "text/html";
               ~*^/ae2/. "text/plain";
            }
          '';
        extraConfig =
          { proxyConfig, ... }:
          ''
            location = /map {
              return 308 $scheme://$http_host/map/;
            }
            location /map/ {
              proxy_pass http://127.0.0.1:8100/;
              ${proxyConfig}
            }
            location = /ae2 {
              return 308 $scheme://$http_host/ae2/;
            }
            location /ae2/ {
              proxy_pass http://127.0.0.1:2324/;
              add_header Content-Type $ae2_content_type always;
              ${proxyConfig}
            }
            location = /modpack.zip {
              alias ${serverPackage.client};
            }
          '';
      }).config
      {
        users.users.minecraft = {
          isSystemUser = true;
          group = "minecraft";
        };
        users.groups.minecraft = { };

        sops.secrets.minecraft = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "minecraft";
          group = "minecraft";
        };

        systemd.services.http-minecraft.serviceConfig.BindReadOnlyPaths = [
          serverPackage.client
        ];

        systemd.services.minecraft-ccsftp = {
          after = [ "minecraft.service" ];
          wants = [ "minecraft.service" ];

          serviceConfig = {
            User = "minecraft";
            Group = "minecraft";

            Nice = -3;
            BindPaths = [ svcConfig.dataDir ];
            WorkingDirectory = svcConfig.dataDir;

            Type = "simple";
            ExecStart = [ "${pkgs.CCSFTP}/bin/ccsftp -root=./world/computercraft/computer/ -listen=:25522" ];
          };

          wantedBy = [ "multi-user.target" ];
        };

        systemd.services.minecraft =
          let
            depPkgs = [
              pkgs.coreutils
              pkgs.envsubst
              pkgs.findutils
              pkgs.bash
              pkgs.gawk
              pkgs.gnugrep
              pkgs.gnused
              pkgs.wget
              pkgs.curl
              pkgs.unzip
            ];
          in
          {
            path = depPkgs;
            confinement.packages = depPkgs;

            serviceConfig = {
              User = "minecraft";
              Group = "minecraft";

              Environment = [ "SERVER_DIR=${svcConfig.dataDir}" ];
              EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.minecraft.path;

              BindPaths = [ svcConfig.dataDir ];
              BindReadOnlyPaths = [
                "${serverPackage}/server:/server"
                "/usr/bin/env"
              ];
              WorkingDirectory = svcConfig.dataDir;
              StateDirectory = ifDefaultData "minecraft";

              Nice = -4;
              ExecStartPre = [ "${serverPackage}/server/minecraft-install.sh" ];
              ExecStart = [ "${svcConfig.dataDir}/minecraft-run.sh" ];
            };

            wantedBy = [ "multi-user.target" ];
          };

        environment.persistence."/nix/persist/minecraft" = ifDefaultData {
          hideMounts = true;
          directories = [
            {
              directory = defaultDataDir;
              user = "minecraft";
              group = "minecraft";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
