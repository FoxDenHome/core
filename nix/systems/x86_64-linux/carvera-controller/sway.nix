{ config, ... } :
{
  programs.sway.enable = true;

  systemd.user.services.sway = {
    unitConfig = {
      Description = "Sway Wayland compositor";
      StartLimitIntervalSec = 0;
      ConditionUser = "appliance";
    };

    serviceConfig = {
      ExecStart = "${config.programs.sway.package}/bin/sway";
      Restart = "always";
      RestartSec = "1s";
      Environment = [
        "SDL_VIDEODRIVER=wayland"
        "BEMENU_BACKEND=wayland"
      ];
      WorkingDirectory = "%h";
    };

    wantedBy = [ "default.target" ];
  };
}
