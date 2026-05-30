{ lib, config, ... }:
let
  sleepYesNo = if config.foxDen.sleep.enable then "yes" else "no";
in
{
  options.foxDen.sleep.enable = lib.mkEnableOption "Enable sleep/hibernate support";

  config.systemd.sleep.settings.Sleep = {
    AllowSuspend = sleepYesNo;
    AllowHibernation = sleepYesNo;
    AllowSuspendThenHibernate = sleepYesNo;
    AllowHybridSleep = sleepYesNo;
  };
}
