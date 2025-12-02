{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.foxcaves;
in
{
  options.foxDen.services.foxcaves = {
    storageDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/foxcaves/storage";
    };
  }
  // services.mkOptions {
    svcName = "foxcaves";
    name = "foxCaves";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "foxcaves";
      }).config
      (foxDenLib.services.redis.make {
        inherit pkgs config svcConfig;
        name = "foxcaves";
      }).config
      {
        sops.secrets.foxcaves = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "foxcaves";
          group = "foxcaves";
        };
        environment.etc."foxcaves/production.lua".source = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.foxcaves.path;

        foxDen.hosts.hosts.${svcConfig.host}.webservice.enable = true;

        systemd.services.foxcaves = {
          after = [ "redis-foxcaves.service" ];
          requires = [ "redis-foxcaves.service" ];

          confinement.packages = [
            # TODO
          ];
          path = [
            # TODO
          ];

          serviceConfig = {
            ExecStart = [ "${pkgs.foxcaves}/bin/foxcaves" ];

            User = "foxcaves";
            Group = "foxcaves";
            DynamicUser = false;

            Environment = [
              "ENVIRONMENT=production"
            ];
            BindReadOnlyPaths = foxDenLib.services.mkEtcPaths [
              "foxcaves/production.lua"
            ];
            BindPaths = [
              "-${svcConfig.storageDir}"
            ];
            StateDirectory = "foxcaves";
          };

          wantedBy = [ "multi-user.target" ];
        };

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [ "foxcaves" ];
              service = "foxcaves";
            }
          ];
        };

        environment.persistence."/nix/persist/foxcaves" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/foxcaves";
              user = "foxcaves";
              group = "foxcaves";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
