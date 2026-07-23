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
    systemd.tmpfiles.rules = [
      "d /run/nut-secrets 0700 root root"
    ];

    systemd.services.upsd-generate-passwords = {
      description = "NUT upsd random generate service passwords";
      after = [ "network.target" ];
      before = [
        "upsmon.service"
        "upsd.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "ups-secrets.sh" ''
          set -ex
          for user in (upsmon); do
            if [ ! -f "/run/nut-secrets/$user" ]; then
              dd if=/dev/urandom bs=32 count=1 | base64 > of="/run/nut-secrets/$user"
            fi
            chmod 600 "/run/nut-secrets/$user"
          done
        '';
        RemainAfterExit = true;
      };
      wantedBy = [ "multi-user.target" ];
    };

    power.ups = {
      enable = true;
      ups.ups-rack = {
        driver = "snmp-ups";
        port = "ups-rack.foxden.network:161";
        directives = [
          "community = monitor_sprFp7"
          "snmp_version = v1"
          "mibs = pw"
          "override.battery.charge.low = svcConfig.lowBatteryLevel"
        ];
      };
      users = {
        upsmon = {
          passwordFile = "/run/nut-secrets/upsmon";
        };
      };
      upsmon = {
        settings = {
          MINSUPPLIES = 1;
          NOTIFYFLAG = [
            [
              "ONLINE"
              "SYSLOG+EXEC"
            ]
            [
              "ONBATT"
              "SYSLOG+EXEC"
            ]
            [
              "LOWBATT"
              "SYSLOG+EXEC"
            ]
          ];
          POWERDOWNFLAG = null;
        };
        monitor.ups-rack = {
          type = "master";
          powerValue = 2;
          user = "upsmon";
          passwordFile = "/run/nut-secrets/upsmon";
        };
      };
      schedulerRules = "${pkgs.writeText "upssched.conf" ''
        CMDSCRIPT ${pkgs.writeShellScript "cmdscript.sh" cmdScript}
        AT ONBATT * EXECUTE onbatt
        AT ONLINE * EXECUTE onpower
        ${
          if svcConfig.secondsOnBattery > 0 then
            "AT ONBATT * START-TIMER shutdown ${svcConfig.secondsOnBattery}"
          else
            ""
        }
        AT ONLINE * CANCEL-TIMER shutdown
        AT LOWBATT * EXECUTE shutdown
      ''}";
    };
  };
}
