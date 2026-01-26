{
  config,
  pkgs,
  hostName,
  lib,
  ...
}:
let
  pusherSubnets = [
    "10.6.11.0/24"
    "fd2c:f4cb:63be:6::b00/120"
  ];
in
{
  options.foxDen.deploy.push = with lib.types; {
    enable = lib.mkEnableOption "Enable push updates";
    interface = lib.mkOption {
      type = str;
      default = "default";
      description = "The interface on which the pusher is expected to reach this host.";
    };
  };

  config = lib.mkIf config.foxDen.deploy.push.enable {
    users.users.nixpush = {
      isNormalUser = true;
      autoSubUidGidRange = false;
      home = "/home/nixpush";
      shell = pkgs.fish;
      group = "nixpush";
      extraGroups = [
        "maintainers"
        "wheel"
      ];
      openssh.authorizedKeys.keys = [
        "command=\"/etc/foxden/nixos/update.sh\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPe7TWvlE5VP9fn5YBHE0qsYZpD4Ev0He2aTUWHJBo2y nixpush"
      ];
    };
    users.groups.nixpush = { };

    foxDen.firewall.rules = map (subnet: {
      table = "filter";
      chain = "forward";
      action = "accept";
      source = subnet;
      gateway = "router";
      destination = {
        host = hostName;
        interface = config.foxDen.deploy.push.interface;
      };
      dstport = 22;
      protocol = "tcp";
      comment = "nixpush-allow-ssh";
    }) pusherSubnets;
  };
}
