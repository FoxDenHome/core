{ pkgs, lib, config, ... }:
let
  svcConfig = config.foxDen.services.netdata;

  mkDir = (dir: {
    directory = dir;
    user = config.services.netdata.user;
    group = config.services.netdata.group;
    mode = "u=rwx,g=,o=";
  });
in
{
  options.foxDen.services.netdata = {
    enable = lib.mkEnableOption "netdata";
  };

  config = lib.mkIf svcConfig.enable {
    services.netdata.enable = true;

    environment.persistence."/nix/persist/netdata" = ifDefaultData {
      hideMounts = true;
      directories = [
        (mkDir "/var/lib/netdata")
        (mkDir "/var/cache/netdata")
      ];
    };
}
