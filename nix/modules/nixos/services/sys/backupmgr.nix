{ pkgs, foxDenLib, lib, config, ... }:
let
  svcConfig = config.foxDen.services.backupmgr;

  commonServiceConfig = {
    Type = "simple";
    Restart = "no";
    BindPaths = [ "/var/cache/restic" ] ++ svcConfig.targetDirs;
    BindReadOnlyPaths = [
      "/nix/persist"
    ] ++ svcConfig.sourceDirs ++ (foxDenLib.services.mkEtcPaths [
      "backupmgr/config.json"
    ]);
    PrivateUsers = lib.mkForce false;
  };
  commonPackages = [ pkgs.restic ];
in
{
  options.foxDen.services.backupmgr = {
    sourceDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional directories to back up.";
    };
    targetDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Directories to back up to.";
    };
  } // foxDenLib.services.mkOptions { svcName = "backupmgr"; name = "Backup Manager"; };

  config = lib.mkIf svcConfig.enable (lib.mkMerge [
    (foxDenLib.services.make {
      inherit pkgs config svcConfig;
      name = "backupmgr-prune";
    }).config
    (foxDenLib.services.make {
      inherit pkgs config svcConfig;
      name = "backupmgr-backup";
    }).config
    {
      foxDen.services.backupmgr.host = lib.mkDefault "";

      environment.systemPackages = [
        pkgs.restic
        pkgs.backupmgr
        pkgs.fuse
      ];

      systemd.services.backupmgr-backup = {
        path = commonPackages;
        confinement.packages = commonPackages;

        conflicts = [ "backupmgr-prune.service" ];
        serviceConfig = commonServiceConfig // {
          ExecStart = [ "${pkgs.backupmgr}/bin/backupmgr --mode=backup" ];
        };
      };

      systemd.timers.backupmgr-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          RandomizedDelaySec = "30m";
        };
      };

      systemd.services.backupmgr-prune = {
        path = commonPackages;
        confinement.packages = commonPackages;

        conflicts = [ "backupmgr-backup.service" ];
        serviceConfig = commonServiceConfig // {
          ExecStart = [ "${pkgs.backupmgr}/bin/backupmgr --mode=prune" ];
        };
      };

      systemd.timers.backupmgr-prune = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "monthly";
          RandomizedDelaySec = "72h";
        };
      };

      sops.secrets.backupmgr = config.lib.foxDen.sops.mkIfAvailable {};

      systemd.tmpfiles.rules = [
        "D /mnt/backupmgr 0700 root root"
      ];

      environment.etc."backupmgr/config.json" = config.lib.foxDen.sops.mkIfAvailable {
        source = config.sops.secrets.backupmgr.path;
      };

      environment.persistence."/nix/persist/restic" = {
        hideMounts = true;
        directories = [
          { directory = "/var/cache/restic"; mode = "u=rwx,g=,o="; }
        ];
      };
    }
  ]);
}
