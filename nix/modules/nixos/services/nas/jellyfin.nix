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
      user = config.services.jellyfin.user;
      group = config.services.jellyfin.group;
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.jellyfin;
in
{
  options.foxDen.services.jellyfin = {
    mediaDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory to store Jellyfin media";
    };
  }
  // services.http.mkOptions {
    svcName = "jellyfin";
    name = "Jellyfin media server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "jellyfin";
        gpu = true;
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-jellyfin";
        target = "proxy_pass http://127.0.0.1:8096;";
      }).config
      {
        services.jellyfin.enable = true;
        services.jellyfin.group = "share";

        users.users.jellyfin.home = "${config.services.jellyfin.dataDir}/home";

        systemd.services.jellyfin = {
          serviceConfig = {
            ExecStartPre = [
              "${pkgs.coreutils}/bin/mkdir -p \${HOME}"
            ];
            BindPaths = [
              config.services.jellyfin.cacheDir
              config.services.jellyfin.configDir
              config.services.jellyfin.dataDir
              config.services.jellyfin.logDir
            ];
            BindReadOnlyPaths = [
              "${svcConfig.mediaDir}:/media"
            ]
            ++ services.mkEtcPaths [
              "fonts"
            ];
          };
        };

        environment.persistence."/nix/persist/jellyfin" = {
          hideMounts = true;
          directories = [
            (mkDir config.services.jellyfin.cacheDir)
            (mkDir config.services.jellyfin.configDir)
            (mkDir config.services.jellyfin.dataDir)
            (mkDir config.services.jellyfin.logDir)
          ];
        };
      }
    ]
  );
}
