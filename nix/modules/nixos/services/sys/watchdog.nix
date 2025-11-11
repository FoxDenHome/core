{
  pkgs,
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
    systemd.watchdog = {
      device = svcConfig.device;
      kexecTime = null;
      rebootTime = null;
      runtimeTime = "60s";
    };
  };
}
