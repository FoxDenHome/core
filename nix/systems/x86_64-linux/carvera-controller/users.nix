{ pkgs, ... } :
{
  environment.systemPackages = with pkgs; [
    wlr-randr
    wayvnc
    network-manager-applet
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
      { directory = "/var/lib/appliance-data"; owner = "appliance"; group = "appliance"; mode = "u=rwx,g=,o="; }
    ];
  };
}
