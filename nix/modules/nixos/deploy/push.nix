{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.foxDen.deploy.push = lib.mkEnableOption "Enable push updates";
  config = lib.mkIf config.foxDen.deploy.push {
    users.users.nixpush = {
      isNormalUser = true;
      autoSubUidGidRange = false;
      home = "/home/nixpush";
      shell = pkgs.fish;
      group = "nixpush";
      extraGroups = [ "maintainers" "wheel" ];
      openssh.authorizedKeys.keys = [
        "command=\"/etc/foxden/nixos/update.sh\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPe7TWvlE5VP9fn5YBHE0qsYZpD4Ev0He2aTUWHJBo2y nixpush"
      ];
    };
    users.groups.nixpush = { };
  };
}
