{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  mkDir = (
    dir: {
      directory = dir;
      user = config.services.deluge.user;
      group = config.services.deluge.group;
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.deluge;
in
{
  options.foxDen.services.deluge = {
    downloadsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/deluge/downloads";
      description = "Directory to store Deluge downloads";
    };
    enableHttp = lib.mkEnableOption "HTTP reverse proxy for Deluge Web UI";
  }
  // (services.http.mkOptions {
    svcName = "deluge";
    name = "Deluge BitTorrent Client";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "deluge-pre";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "deluged";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "delugeweb";
        inherit svcConfig pkgs config;
      }).config
      (lib.mkIf svcConfig.enableHttp
        (services.http.make {
          inherit svcConfig pkgs config;
          name = "http-deluge";
          target = "proxy_pass http://127.0.0.1:8112;";
        }).config
      )
      {
        services.deluge = {
          enable = true;
          web = {
            enable = true;
          };
          dataDir = "/var/lib/deluge";
          config = {
            download_location = "/downloads";
          };
          declarative = true;
          group = "share";
          authFile = "${config.services.deluge.dataDir}/auth";
        };

        systemd.services.deluge-pre = {
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            BindPaths = [ config.services.deluge.dataDir ];

            ExecStart = [
              "${pkgs.coreutils}/bin/mkdir -p ${config.services.deluge.dataDir}/downloads ${config.services.deluge.dataDir}/.config/deluge"
            ];

            User = config.services.deluge.user;
            Group = config.services.deluge.group;

            Restart = "no";
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };

        systemd.services.deluged = {
          requires = [ "deluge-pre.service" ];
          bindsTo = [ "deluge-pre.service" ];
          after = [ "deluge-pre.service" ];

          serviceConfig = {
            BindPaths = [
              config.services.deluge.dataDir
              "${svcConfig.downloadsDir}:/downloads"
            ];
          };
        };

        systemd.services.delugeweb = {
          requires = [ "deluge-pre.service" ];
          bindsTo = [ "deluge-pre.service" ];
          after = [ "deluge-pre.service" ];

          serviceConfig = {
            BindPaths = [
              config.services.deluge.dataDir
              "${svcConfig.downloadsDir}:/downloads"
            ];
          };
        };

        environment.persistence."/nix/persist/deluge" = {
          hideMounts = true;
          directories = [
            (mkDir config.services.deluge.dataDir)
          ];
        };
      }
    ]
  );
}
