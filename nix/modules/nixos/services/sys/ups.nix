{
  lib,
  pkgs,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.ups;

  cmdScript = ''
    echo "$@" >> /tmp/nut-cmdscript.log
  '';
in
{
  options.foxDen.services.ups = {
    enable = lib.mkEnableOption "NUT (UPS)";
    lowBatteryLevel = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Battery level (%) to trigger shutdown";
    };
    secondsOnBattery = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Seconds of time on battery to trigger shutdown (0 to disable)";
    };
  };

  config = lib.mkIf svcConfig.enable {
    power.ups = {
      enable = true;
      ups.ups-rack = {
        driver = "snmp-ups";
        port = "ups-rack.foxden.network:161";
        community = "monitor_sprFp7";
        snmp_version = "v1";
        mibs = "pw";
        "override.battery.charge.low" = svcConfig.lowBatteryLevel;
      };
      schedulerRules = pkgs.writeText "upssched.conf" ''
        CMDSCRIPT ${pkgs.writeShellScreipt "cmdscript.sh"}
        AT ONBATT * EXECUTE onbatt
        AT ONLINE * EXECUTE onpower
        ${
          if svcCondiv.secondsOnBattery > 0 then
            "AT ONBATT * START-TIMER shutdown ${svcConfig.secondsOnBattery}"
          else
            ""
        }
        AT ONLINE * CANCEL-TIMER shutdown
        AT LOWBATT * EXECUTE shutdown
      '';
    };
  };
}
