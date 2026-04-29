{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.rmfakecloud;
  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";
in
{
  options.foxDen.services.rmfakecloud = {
  }
  // (services.http.mkOptions {
    svcName = "restic-server";
    name = "Restic Backup Server";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-rmfakecloud";
        target = "access_log /proc/self/stdout; proxy_pass http://127.0.0.1:3000;";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "rmfakecloud";
      }).config
      {
        sops.secrets.rmfakecloud = config.lib.foxDen.sops.mkIfAvailable { };

        services.rmfakecloud = {
          enable = true;
          port = 3000;
          storageUrl = "${proto}://${hostName}";
          environmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.rmfakecloud.path;
          extraSettings = {
            DATADIR = "/var/lib/rmfakecloud";
            RM_TRUST_PROXY = "true";
            RM_HTTPS_COOKIE = if svcConfig.tls.enable then "true" else "";
          };
        };

        systemd.services.rmfakecloud = {
          serviceConfig = {
            StateDirectory = "rmfakecloud";
          };
        };
      }
    ]
  );
}
