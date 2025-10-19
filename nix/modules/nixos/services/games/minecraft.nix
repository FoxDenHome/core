{ foxDenLib, pkgs, lib, config, ... }:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.minecraft;

  defaultDataDir = "/var/lib/minecraft";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);

  jrePackage = import ../../../../packages/foxden-minecraft/jre.nix { inherit pkgs; };
  serverPackage = pkgs.foxden-minecraft;
in
{
  options.foxDen.services.minecraft = with lib.types; {
    dataDir = lib.mkOption {
      type = path;
      default = defaultDataDir;
      description = "Directory to store Minecraft data";
    };
  } // (services.http.mkOptions { svcName = "minecraft"; name = "Minecraft server"; });

  config = lib.mkIf svcConfig.enable (lib.mkMerge [
    (services.make {
      inherit svcConfig pkgs config;
      name = "minecraft";
    }).config
    {
      users.users.minecraft = {
        isSystemUser = true;
        group = "minecraft";
      };
      users.groups.minecraft = {};

      environment.systemPackages = [ pkgs.unzip ];

      systemd.services.minecraft = {
        confinement.packages = [
          jrePackage
          pkgs.coreutils
          pkgs.findutils
          pkgs.bash
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.wget
          pkgs.curl
          pkgs.unzip
        ];
        path = [
          jrePackage
          pkgs.coreutils
          pkgs.findutils
          pkgs.bash
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.wget
          pkgs.curl
          pkgs.unzip
        ];

        serviceConfig = {
          User = "minecraft";
          Group = "minecraft";

          Environment = [
            "SERVER_DIR=${svcConfig.dataDir}"
          ];

          BindPaths = [
            svcConfig.dataDir
          ];
          BindReadOnlyPaths = [
            "${serverPackage}/server:/server"
            "/usr/bin/env"
          ];
          WorkingDirectory = svcConfig.dataDir;

          ExecStartPre = [ "${serverPackage}/server/minecraft-install.sh" ];
          ExecStart = [ "${svcConfig.dataDir}/minecraft-run.sh" ];

          StateDirectory = ifDefaultData "minecraft";
        };

        wantedBy = [ "multi-user.target" ];
      };

      environment.persistence."/nix/persist/minecraft" = ifDefaultData {
        hideMounts = true;
        directories = [
          { directory = defaultDataDir; user = "minecraft"; group = "minecraft"; mode = "u=rwx,g=,o="; }
        ];
      };
    }
  ]);
}
