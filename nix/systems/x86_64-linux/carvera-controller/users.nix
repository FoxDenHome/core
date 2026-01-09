{ pkgs, ... }:
{
  users.users.appliance = {
    isSystemUser = true;
    group = "appliance";
    home = "/run/appliance";
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
        "+${pkgs.coreutils}/bin/rm -rf /run/appliance"
        "+${pkgs.coreutils}/bin/mkdir -p /run/appliance /run/appliance/tmp"
        "+${pkgs.coreutils}/bin/chmod 700 /run/appliance/tmp"
        "+${pkgs.coreutils}/bin/chown -R appliance:appliance /run/appliance"
        "+${pkgs.coreutils}/bin/chmod -R 700 /run/appliance"
        "${pkgs.rsync}/bin/rsync -av --delete --exclude=tmp ${./appliance-home}/ /run/appliance/"
        "${pkgs.coreutils}/bin/chmod 500 /run/appliance"
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/appliance/data /run/appliance/tmp/.cache /run/appliance/tmp/.local /run/appliance/tmp/.config/fish /run/appliance/tmp/.kivy/icons /run/appliance/tmp/.kivy/icon /run/appliance/tmp/.kivy/logs /run/appliance/tmp/.kivy/mods"
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
