{ lib, config, ... }:
let
  svcConfig = config.foxDen.services.apcupsd;
in
{
  options.foxDen.services.apcupsd = {
    enable = lib.mkEnableOption "apcupsd";
    batteryLevel = lib.mkOption {
      type = lib.types.ints.positive;
      default = 50;
      description = "Battery level (%) to trigger shutdown";
    };
    minutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Minutes of battery life to trigger shutdown";
    };
  };

  config = lib.mkIf svcConfig.enable {
    services.apcupsd.enable = true;
    services.apcupsd.configText = ''
      UPSNAME ups-rack
      UPSCABLE ether
      UPSTYPE snmp
      NISIP 127.0.0.1
      DEVICE ups-rack.foxden.network:161:APC_NOTRAP:apcupsd
      BATTERYLEVEL ${toString svcConfig.batteryLevel}
      MINUTES ${toString svcConfig.minutes}
    '';
  };
}
