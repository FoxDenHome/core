{ pkgs, ... } :
{
  users.users.appliance = {
    isSystemUser = true;
    group = "appliance";
    home = "/run/appliance";
    shell = pkgs.fish;
    linger = true;
  };
  users.groups.appliance = {};
  systemd.tmpfiles.rules = [
    "D /run/appliance 0700 appliance appliance"
  ];
}
