{ config, pkgs, ... } :
let
  swayPkgs = with pkgs; [
    wlr-randr
    wayvnc
    networkmanagerapplet
  ];
in
{
  environment.systemPackages = swayPkgs;
  programs.sway.enable = true;

  services.seatd.enable = true;

  services.xserver.videoDrivers = [ "modesetting" ];
  hardware.graphics.enable = true;

  systemd.user.services.sway = {
    unitConfig = {
      Description = "Sway Wayland compositor";
      StartLimitIntervalSec = 0;
      ConditionUser = "appliance";
    };

    path = swayPkgs;

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
