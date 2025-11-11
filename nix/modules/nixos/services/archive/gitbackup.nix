{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.gitbackup;

  defaultDataDir = "/var/lib/gitbackup";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);
  ifNotDefaultData = lib.mkIf (svcConfig.dataDir != defaultDataDir);
in
{
  options.foxDen.services.gitbackup = {
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = defaultDataDir;
      description = "Directory to store gitbackup data";
    };
  }
  // (services.http.mkOptions {
    svcName = "gitbackup";
    name = "Git backup";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "gitbackup";
        inherit svcConfig pkgs config;
      }).config
      {
        foxDen.services.gitbackup.host = lib.mkDefault "";

        systemd.services.gitbackup = {
          confinement.packages = [
            pkgs.git
          ];

          path = [
            pkgs.git
          ];

          serviceConfig = {
            DynamicUser = true;
            Type = "oneshot";
            Restart = "no";

            Environment = [
              "GITHUB_ORGANIZATIONS=foxCaves,FoxDenHome,FoxBukkit,MoonHack,PawNode,SpaceAgeMP,WSVPN"
              "\"BACKUP_ROOT=${svcConfig.dataDir}\""
            ];

            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.lib.foxDen.sops.mkGithubTokenPath;

            BindPaths = ifNotDefaultData [
              "${svcConfig.dataDir}"
            ];

            ExecStart = [ "${pkgs.gitbackup}/bin/gitbackup-single" ];

            StateDirectory = ifDefaultData "gitbackup";
          };
        };

        systemd.timers.gitbackup = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "hourly";
            RandomizedDelaySec = "45m";
          };
        };
      }
    ]
  );
}
