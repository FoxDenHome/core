{
  lib,
  pkgs,
  config,
  hostName,
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
      description = "Battery level (%) to trigger low battery state (and shutdown)";
    };
    secondsRuntimeLeft = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5 * 60;
      description = "Seconds of time left to trigger low battery state (and shutdown)";
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
          adduser() {
            local user="$1"
            if [ ! -f "/run/nut-secrets/$user" ]; then
              dd if=/dev/urandom bs=32 count=1 | base64 > "/run/nut-secrets/$user"
            fi
            chmod 600 "/run/nut-secrets/$user"
          }
          adduser upsmon
        '';
        RemainAfterExit = true;
      };
      wantedBy = [ "multi-user.target" ];
    };

    foxDen.firewall.rules = [
      {
        table = "filter";
        chain = "forward";
        action = "accept";
        source = {
          host = hostName;
        };
        destination = {
          host = "ups-rack";
          system = "landevices";
        };
        dstport = 161;
        protocol = "udp";
        comment = "snmp-${hostName}-ups-rack-allow-snmp";
      }
    ];

    power.ups = {
      enable = true;
      ups.ups-rack = {
        driver = "snmp-ups";
        port = "ups-rack.foxden.network:161";
        directives = [
          "community = ${config.lib.foxDen.snmp.ro}"
          "snmp_version = v1"
          "mibs = eaton_pw_nm2"
          "override.battery.charge.low = ${toString svcConfig.lowBatteryLevel}"
          "override.battery.runtime.low = ${toString svcConfig.secondsRuntimeLeft}"
        ];
      };
      users = {
        upsmon = {
          passwordFile = "/run/nut-secrets/upsmon";
        };
      };
      upsmon = {
        settings = {
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
          SHUTDOWNCMD = null;
          POWERDOWNFLAG = null;
        };
        monitor.ups-rack = {
          type = "primary";
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
            "AT ONBATT * START-TIMER shutdown ${toString svcConfig.secondsOnBattery}"
          else
            ""
        }
        AT ONLINE * CANCEL-TIMER shutdown
        AT LOWBATT * EXECUTE shutdown
      ''}";
    };
  };
}
