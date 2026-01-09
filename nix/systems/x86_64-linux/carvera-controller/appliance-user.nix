{ pkgs, ... }:
{
  users.users.appliance = {
    isNormalUser = true;
    autoSubUidGidRange = false;
    group = "appliance";
    home = "/home/appliance";
    shell = pkgs.fish;
    linger = true;
    extraGroups = [
      "dialout"
      "input"
      "render"
      "seat"
      "video"
    ];
  };
  users.groups.appliance = { };

  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="10ce", ATTRS{idProduct}=="eb93", GROUP="dialout"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="10ce", ATTRS{idProduct}=="eb93", GROUP="dialout"
  '';

  home-manager.users.appliance =
    { pkgs, ... }:
    {
      home.stateVersion = "25.11";

      home.file = {
        ".config" = {
          enable = true;
          force = true;
          recursive = true;
          source = ./appliance-config;
          target = ".config";
        };
      };
    };

  environment.systemPackages = with pkgs; [
    carvera-controller
  ];
}
