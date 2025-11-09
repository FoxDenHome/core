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
    home = "/run/appliance";
    shell = pkgs.fish;
    linger = true;
    extraGroups = [ "seat" "video" "render" ];
  };
  users.groups.appliance = {};

  systemd.tmpfiles.rules = [
    "D /run/appliance 0700 appliance appliance"
  ];

  systemd.services.appliance-setup = {
    serviceConfig = {
      User = "appliance";
      Group = "appliance";
      WorkingDirectory = "/run/appliance";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${pkgs.coreutils}/bin/chmod -R 700 /run/appliance"
        "${pkgs.rsync}/bin/rsync -av --delete ${./appliance-home}/ /run/appliance/"
        "${pkgs.coreutils}/bin/chmod 500 /run/appliance"
      ];
    };

    wantedBy = [ "multi-user.target" ];
  };

  environment.persistence."/nix/persist/appliance" = {
    hideMounts = true;
    directories = [
      { directory = "/var/lib/appliance-data"; user = "appliance"; group = "appliance"; mode = "u=rwx,g=,o="; }
    ];
  };
}
