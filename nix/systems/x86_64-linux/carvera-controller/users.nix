{ pkgs, ... }:
{
  users.users.appliance = {
    isSystemUser = true;
    group = "appliance";
    home = "/var/lib/appliance";
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
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/appliance/.config"
        "-${pkgs.coreutils}/bin/chmod -R 700 /var/lib/appliance/.config"
        "${pkgs.rsync}/bin/rsync -av ${./appliance-config}/ /var/lib/appliance/.config/"
        "${pkgs.coreutils}/bin/chmod -R 700 /var/lib/appliance/.config"
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/appliance/data"
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
        directory = "/var/lib/appliance";
        user = "appliance";
        group = "appliance";
        mode = "u=rwx,g=,o=";
      }
    ];
  };
}
