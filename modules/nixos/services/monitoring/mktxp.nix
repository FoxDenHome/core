{ foxDenLib, pkgs, lib, config, ... }:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.mktxp;
in
{
  options.foxDen.services.mktxp = {

  } // services.mkOptions { svcName = "mktxp"; name = "MKTXP monitoring server"; };

  config = lib.mkIf svcConfig.enable (lib.mkMerge [
    (services.make {
      name = "mktxp";
      inherit svcConfig pkgs config;
    }).config
    {
      sops.secrets.mktxp = config.lib.foxDen.sops.mkIfAvailable {
        mode = "0400";
        owner = "mktxp";
        group = "mktxp";
      };

      users.users.mktxp = {
        isSystemUser = true;
        group = "mktxp";
      };
      users.groups.mktxp = {};

      systemd.services.mktxp = {
        confinement.packages = [
          pkgs.gnused
          pkgs.which
        ];
        path = [
          pkgs.gnused
          pkgs.which
        ];

        serviceConfig = {
          ExecStartPre = [
            "${pkgs.coreutils}/bin/touch /tmp/mktxp.conf"
            "${pkgs.coreutils}/bin/chmod 600 /tmp/mktxp.conf"
            "${pkgs.bash}/bin/bash -c 'cat ${./mktxp.conf} | sed \"s/__MTIK_USERNAME__/$MTIK_USERNAME/g\" | sed \"s/__MTIK_PASSWORD__/$MTIK_PASSWORD/g\" > /tmp/mktxp.conf'"
          ];

          ExecStart = [
            "${pkgs.mktxp}/bin/mktxp --cfg-dir /tmp export"
          ];

          Type = "simple";

          User = "mktxp";
          Group = "mktxp";

          EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.mktxp.path;
        };

        wantedBy = [ "multi-user.target" ];
      };
    }
  ]);
}
