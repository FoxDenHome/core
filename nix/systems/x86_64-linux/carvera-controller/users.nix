{ pkgs, ... } :
{
  users.users.appliance = {
    isSystemUser = true;
    group = "appliance";
    home = "/run/appliance";
    shell = pkgs.fish;
    linger = true;
    extraGroups = [ "seat" "video" "render" ];
  };
  users.groups.appliance = {};

  systemd.services.appliance-setup = {
    serviceConfig = {
      User = "appliance";
      Group = "appliance";
      WorkingDirectory = "/run/appliance";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "+${pkgs.coreutils}/bin/mkdir -p /run/appliance"
        "+${pkgs.coreutils}/bin/chown -R appliance:appliance /run/appliance"
        "+${pkgs.coreutils}/bin/chmod -R 700 /run/appliance"
        "${pkgs.rsync}/bin/rsync -av --delete ${./appliance-home}/ /run/appliance/"
        "+${pkgs.coreutils}/bin/mkdir -p /run/appliance/tmp"
        "${pkgs.coreutils}/bin/chmod 700 /run/appliance/tmp"
        "${pkgs.coreutils}/bin/chmod 500 /run/appliance"
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/appliance/data"
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/appliance/.cache"
      ];
    };

    wantedBy = [ "multi-user.target" ];
  };

  environment.persistence."/nix/persist/appliance" = {
    hideMounts = true;
    directories = [
      { directory = "/var/lib/appliance"; user = "appliance"; group = "appliance"; mode = "u=rwx,g=,o="; }
    ];
  };
}
