{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.affine;
  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";
in
{
  options.foxDen.services.affine = services.http.mkOptions {
    name = "AFFiNE";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-affine";
        target = "proxy_pass http://127.0.0.1:3010;";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "affine";
      }).config
      (foxDenLib.services.redis.make {
        inherit pkgs config svcConfig;
        name = "affine";
      }).config
      {
        foxDen.services.affine.oAuth.overrideService = true;

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} = (
            services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/oauth/callback";
            }
          );
        };

        foxDen.services.postgresql = {
          enable = true;
          services = [
            {
              database = "affine";
              service = "affine";
            }
          ];
        };

        users.users.affine = {
          isSystemUser = true;
          home = "/var/lib/affine";
          group = "affine";
        };
        users.groups.affine = { };

        systemd.services.affine = {
          after = [ "redis-affine.service" ];
          requires = [ "redis-affine.service" ];

          environment = {
            DATABASE_URL = "postgres://affine@localhost/affine?host=/run/postgresql/";
            AFFINE_INDEXER_ENABLED = "false";
            LISTEN_ADDR = "127.0.0.1";
            AFFINE_SERVER_EXTERNAL_URL = "${proto}://${hostName}";
          };

          serviceConfig = {
            StateDirectory = "affine";
            User = "affine";
            Group = "affine";
            ExecStart = [ "${pkgs.affine-server}/bin/affine-server" ];
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
