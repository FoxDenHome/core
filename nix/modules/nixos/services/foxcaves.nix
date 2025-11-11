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
    dataVolume = lib.mkOption {
      type = lib.types.str;
      default = "storage";
    };
  }
  // services.mkOptions {
    svcName = "foxcaves";
    name = "foxCaves";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        inherit pkgs config svcConfig;
        name = "foxcaves";
        oci = {
          image = "ghcr.io/foxcaves/foxcaves/foxcaves:latest";
          volumes = [
            "ssl:/etc/letsencrypt"
            "${svcConfig.dataVolume}:/var/www/foxcaves/storage"
            (config.lib.foxDen.sops.mkIfAvailable "${config.sops.secrets.foxcaves.path}:/var/www/foxcaves/config/production.lua:ro")
          ];
          environment = {
            "ENVIRONMENT" = "production";
          };
          extraOptions = [
            "-e MYSQL_*"
          ];
        };
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

        foxDen.hosts.hosts.${svcConfig.host}.webservice.enable = true;

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              name = "foxcaves";
              proxy = true;
              targetService = "podman-foxcaves";
            }
          ];
        };
      }
    ]
  );
}
