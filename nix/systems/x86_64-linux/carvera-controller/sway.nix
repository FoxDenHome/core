{ config, pkgs, ... } :
{
  environment.systemPackages = with pkgs; [
    bemenu
    wlr-randr
    wayvnc
    config.programs.sway.package
    config.programs.i3status.package
  ];
  programs.i3status.enable = true;
  programs.sway.enable = true;
  programs.nm-applet.enable = true;

  services.seatd.enable = true;

  services.xserver.videoDrivers = [ "modesetting" ];
  hardware.graphics.enable = true;

  systemd.user.services.sway = {
    unitConfig = {
      Description = "Sway Wayland compositor";
      StartLimitIntervalSec = 0;
      ConditionUser = "appliance";
    };

    path = [
      "/run/current-system/sw"
    ];

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
