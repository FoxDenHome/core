{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.darksignsonline;
in
{
  options.foxDen.services.darksignsonline = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Domain name for the service";
    };
    tls = lib.mkEnableOption "Enable TLS for the service";
  }
  // services.mkOptions {
    svcName = "darksignsonline";
    name = "Dark Signs Online";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        inherit pkgs config svcConfig;
        name = "darksignsonline";
        oci = {
          image = "ghcr.io/doridian/darksignsonline/server:latest";
          volumes = [
            "nginx:/var/lib/nginx"
            "wiki:/var/www/wiki"
            "${config.foxDen.services.mysql.socketPath}:/var/run/mysqld/mysqld.sock:ro"
          ];
          environment = {
            "DOMAIN" = svcConfig.domain;
            "HTTP_MODE" = if svcConfig.tls then "https" else "http";
            "TRUSTED_PROXIES" = lib.concatStringsSep " " config.foxDen.services.trustedProxies;
            "SMTP_FROM" = "noreply@${svcConfig.domain}";
          };
          environmentFiles = [
            (config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.darksignsonline.path)
          ];
          extraOptions = [
            "-e MYSQL_*"
          ];
        };
      }).config
      {
        sops.secrets.darksignsonline = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "darksignsonline";
          group = "darksignsonline";
        };

        foxDen.hosts.hosts.${svcConfig.host}.webservice.enable = true;

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [
                "darksignsonline"
                "darksignsonline_wiki"
              ];
              proxy = true; # TODO: We need to crack the Docker shell for this one...
              service = "podman-darksignsonline";
            }
          ];
        };
      }
    ]
  );
}
