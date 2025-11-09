{ pkgs, ... } :
{
  programs.sway.enable = true;

  users.users.appliance = {
    isSystemUser = true;
    group = "appliance";
    home = "/run/appliance";
    shell = pkgs.fish;
  };
  users.groups.appliance = {};
  systemd.tmpfiles.rules = [
    "D /run/appliance 0700 appliance appliance"
  ];

  systemd.user.services.sway = {
    unitConfig = {
      Description = "Sway Wayland compositor";
      StartLimitIntervalSec = 0;
      ConditionUser = "appliance";
    };

    serviceConfig = {
      ExecStart = "${pkgs.sway}/bin/sway";
      Restart = "always";
      RestartSec = "1s";
      Environment = [
        "SDL_VIDEODRIVER=wayland"
        "BEMENU_BACKEND=wayland"
      ];
      WorkingDirectory = "%h";
    };

    wantedBy = [ "multi-user.target" ];
  };
}