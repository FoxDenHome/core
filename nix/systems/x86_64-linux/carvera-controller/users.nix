{ pkgs, ... } :
{
  environment.systemPackages = with pkgs; [
    wlr-randr
    wayvnc
    networkmanagerapplet
  ];

  users.users.appliance = {
    isSystemUser = true;
    group = "appliance";
    home = ./appliance-home;
    shell = pkgs.fish;
    linger = true;
  };
  users.groups.appliance = {};

  environment.persistence."/nix/persist/appliance" = {
    hideMounts = true;
    directories = [
      { directory = "/var/lib/appliance-data"; user = "appliance"; group = "appliance"; mode = "u=rwx,g=,o="; }
    ];
  };
}
