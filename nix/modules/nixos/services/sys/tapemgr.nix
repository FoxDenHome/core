{
  pkgs,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.tapemgr;
in
{
  options.foxDen.services.tapemgr.enable = lib.mkEnableOption "tapemgr";

  config = lib.mkIf svcConfig.enable {
    boot.kernelModules = [ "sg" ];

    environment.systemPackages = [
      pkgs.tapemgr
      pkgs.tapemgr-ltfs
      pkgs.fuse
    ];

    sops.secrets.tapemgr = config.lib.foxDen.sops.mkIfAvailable { };

    environment.etc."tapemgr/config.json" = config.lib.foxDen.sops.mkIfAvailable {
      source = config.sops.secrets.tapemgr.path;
    };

    systemd.tmpfiles.rules = [
      "D /run/tapemgr-mount 0700 root root"
    ];

    environment.persistence."/nix/persist/tapemgr" = {
      hideMounts = true;
      directories = [
        {
          directory = "/var/lib/tapemgr";
          mode = "u=rwx,g=,o=";
        }
      ];
    };
  };
}
