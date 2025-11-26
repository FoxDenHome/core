{
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.watchdog;
in
{
  options.foxDen.services.watchdog = {
    enable = lib.mkEnableOption "watchdog";
    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/watchdog0";
      description = "Path to the watchdog device";
    };
  };

  config = lib.mkIf svcConfig.enable {
    systemd.settings.Manager = {
      KExecWatchdogSec = null;
      RebootWatchdogSec = null;
      RuntimeWatchdogSec = "60s";
      WatchdogDevice = svcConfig.device;
    };
  };
}
