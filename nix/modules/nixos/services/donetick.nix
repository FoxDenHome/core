{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.donetick;
  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";
  externalUrl = "${proto}://${hostName}";
in
{
  options.foxDen.services.donetick = services.http.mkOptions {
    name = "Donetick";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-donetick";
        target = "proxy_pass http://127.0.0.1:3010;";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "donetick";
      }).config
      {
        sops.secrets.donetick = config.lib.foxDen.sops.mkIfAvailable { };

        foxDen.services.donetick.oAuth.overrideService = true;
        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} = (
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/auth/oauth2";
            }) // {
             allowInsecureClientDisablePkce = true;
             enableLegacyCrypto = true;
             public = false;
            }
          );
        };

        users.users.donetick = {
          isSystemUser = true;
          home = "/var/lib/donetick";
          group = "donetick";
        };
        users.groups.donetick = { };

        foxDen.services.postgresql = {
          enable = true;
          services = [
            {
              database = "donetick";
              service = "donetick";
            }
          ];
        };

        systemd.services.donetick = {
          environment = {
            DT_SINGLE_CIRCLE_INSTANCE = "true";
            DT_SERVER_PORT = "3010";
            DT_SERVER_CORS_ALLOW_ORIGINS = externalUrl;
            DT_SERVER_SERVE_FRONTEND = "true"; # For now maybe?
            DT_ENV = "selfhosted";

            DT_DATABASE_TYPE = "postgres";
            DT_DATABASE_HOST = "/run/postgresql/";
            DT_DATABASE_PORT = "5432";
            DT_DATABASE_USER = "donetick";
            DT_DATABASE_NAME = "donetick";
            DT_DATABASE_MIGRATION = "true";
          }
          // (
            if svcConfig.oAuth.enable then
              {
                DT_DISABLE_PASSWORD_AUTH = "true";
                DT_OAUTH2_ADMIN_GROUPS = "superadmins";
                DT_OAUTH2_NAME = "FoxDen";
                DT_OAUTH2_CLIENT_ID = svcConfig.oAuth.clientId;
                DT_OAUTH2_SCOPE = "openid profile email";
                DT_OAUTH2_AUTH_URL = "https://auth.foxden.network/ui/oauth2";
                DT_OAUTH2_TOKEN_URL = "https://auth.foxden.network/oauth2/token";
                DT_OAUTH2_INFO_URL = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}/userinfo";
                DT_OAUTH2_REDIRECT_URL = "${externalUrl}/auth/oauth2";
              }
            else
              { }
          );

          serviceConfig = {
            StateDirectory = "donetick";
            User = "donetick";
            Group = "donetick";
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.donetick.path;
            ExecStart = [ "${pkgs.donetick-server}/bin/donetick-server" ];
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
