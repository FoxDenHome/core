{ pkgs, ... }:
{
  users.users.appliance = {
    isSystemUser = true;
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

  systemd.services.appliance-setup = {
    serviceConfig = {
      User = "appliance";
      Group = "appliance";
      WorkingDirectory = "/";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${pkgs.coreutils}/bin/mkdir -p /home/appliance/.config"
        "-${pkgs.coreutils}/bin/chmod -R 700 /home/appliance/.config"
        "${pkgs.rsync}/bin/rsync -rv ${./appliance-config}/ /home/appliance/.config/"
        "${pkgs.coreutils}/bin/chmod -R 700 /home/appliance/.config"
        "${pkgs.coreutils}/bin/mkdir -p /home/appliance/data"
      ];
    };
    wantedBy = [ "multi-user.target" ];
  };

  environment.systemPackages = with pkgs; [
    carvera-controller
  ];

  environment.persistence."/nix/persist/appliance" = {
    hideMounts = true;
    directories = [
      {
        directory = "/home/appliance";
        user = "appliance";
        group = "appliance";
        mode = "u=rwx,g=,o=";
      }
    ];
  };
}
