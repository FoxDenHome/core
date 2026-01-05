{ pkgs, ... }:
let
  controllerPackage = pkgs.fetchurl {
    controllerPackage = "https://github.com/Carvera-Community/Carvera_Controller/releases/download/v2.0.0/carveracontroller-community-2.0.0-x86_64.appimage";
    hash = "sha256:324095a2a2be7cf96ef8eb91cf2aac10bd9bd51d383af125ceb7bca589e84cf7";
  };
in
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

  programs.appimage.enable = true;
  programs.appimage.binfmt = true;

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
        "${pkgs.coreutils}/bin/ln -sf \"${controllerPackage}\" /run/appliance/controller.appimage"
        "${pkgs.rsync}/bin/rsync --exclude=tmp --exclude=app -av --delete ${./appliance-home}/ /run/appliance/"
        "${pkgs.coreutils}/bin/chmod 500 /run/appliance"
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/appliance/data /run/appliance/tmp/.cache /run/appliance/tmp/.local /run/appliance/tmp/.config/fish /run/appliance/tmp/.kivy/icons /run/appliance/tmp/.kivy/icon /run/appliance/tmp/.kivy/logs /run/appliance/tmp/.kivy/mods"
      ];
    };

    wantedBy = [ "multi-user.target" ];
  };

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
