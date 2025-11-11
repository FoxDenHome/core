{
  pkgs,
  foxDenLib,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.superfan;
in
{
  options.foxDen.services.superfan = foxDenLib.services.mkOptions {
    svcName = "superfan";
    name = "SuperFan";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "superfan";
        devices = [
          "/dev/ipmi0"
        ];
      }).config
      {
        foxDen.services.superfan.host = "superfan";
        foxDen.hosts.hosts = {
          superfan.interfaces = { };
        };

        systemd.tmpfiles.rules = [
          "d /var/lock/superfan - - - - -"
        ];

        systemd.services.superfan = {
          description = "SuperMicro fan controller daemon";

          path = [ pkgs.lm_sensors ];
          confinement.packages = [ pkgs.lm_sensors ];

          serviceConfig = {
            BindPaths = [ "/var/lock/superfan" ];
            Type = "simple";
            Restart = "always";
            TimeoutStartSec = "30";
            ExecStart = [ "${pkgs.superfan}/bin/superfan" ];
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
