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

  dataDir = config.services.deluge.dataDir;
  floodPort = 3000;

  # Flood talks to deluged as localclient. deluged adds that account to the auth
  # file it loads if missing, so read it from there, not services.deluge.authFile.
  floodStart = pkgs.writeShellScript "flood-start" ''
    set -euo pipefail
    while IFS=: read -r user pass _; do
      if [ "$user" = localclient ]; then
        export FLOOD_OPTION_depass="$pass"
      fi
    done < ${dataDir}/.config/deluge/auth
    if [ -z "''${FLOOD_OPTION_depass:-}" ]; then
      echo "localclient not found in deluge auth file" >&2
      exit 1
    fi
    exec ${lib.getExe pkgs.flood} \
      --host 127.0.0.1 \
      --port ${toString floodPort} \
      --rundir ${dataDir}/flood \
      --auth none \
      --dehost 127.0.0.1 \
      --deport 58846 \
      --deuser localclient \
      --allowedpath /downloads
  '';
in
{
  options.foxDen.services.deluge = {
    downloadsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/deluge/downloads";
      description = "Directory to store Deluge downloads";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Interface (name or IP) to bind BitTorrent traffic to, empty for any";
    };
  }
  // (services.http.mkOptions {
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
        name = "flood";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-deluge";
        target = "proxy_pass http://127.0.0.1:${toString floodPort};";
      }).config
      {
        services.deluge = {
          enable = true;
          dataDir = "/var/lib/deluge";
          # Pin every key Flood's client settings page writes: it sends them
          # all on each save, as null if unchanged, which breaks deluged until
          # a restart restores this file.
          config = {
            download_location = "/downloads";
            dht = true;
            utpex = true;
            listen_interface = svcConfig.interface;
            outgoing_interface = svcConfig.interface;
            listen_ports = [
              6881
              6891
            ];
            random_port = true;
            max_download_speed = -1.0;
            max_upload_speed = -1.0;
            max_upload_slots_global = 4;
            max_upload_slots_per_torrent = -1;
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
              "${pkgs.coreutils}/bin/mkdir -p ${dataDir}/downloads ${dataDir}/.config/deluge ${dataDir}/flood"
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

        systemd.services.flood = {
          requires = [ "deluged.service" ];
          after = [ "deluged.service" ];
          wantedBy = [ "multi-user.target" ];

          # Flood shells out to df for disk usage
          path = [ pkgs.coreutils ];

          serviceConfig = {
            BindPaths = [ dataDir ];
            BindReadOnlyPaths = [ "${svcConfig.downloadsDir}:/downloads" ];

            User = config.services.deluge.user;
            Group = config.services.deluge.group;

            ExecStart = floodStart;
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
