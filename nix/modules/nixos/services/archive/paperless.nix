{
  config,
  foxDenLib,
  lib,
  pkgs,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.paperless;
  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";
  externalUrl = "${proto}://${hostName}";

  cfg = config.services.paperless;

  paperlessServices = [
    "paperless-scheduler"
    "paperless-task-queue"
    "paperless-consumer"
    "paperless-web"
  ];
in
{
  options.foxDen.services.paperless = services.http.mkOptions {
    name = "Paperless(-ngx) server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge (
      (map (
        name:
        (services.make {
          inherit
            name
            svcConfig
            pkgs
            config
            ;
        }).config
      ) paperlessServices)
      ++ [
        (foxDenLib.services.redis.make {
          inherit pkgs config svcConfig;
          name = "paperless";
        }).config
        (services.http.make {
          inherit svcConfig pkgs config;
          name = "http-paperless";
          target = "proxy_pass http://127.0.0.1:${builtins.toString cfg.port};";
        }).config
        {
          foxDen.services.paperless.oAuth.overrideService = true;
          foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
            ${svcConfig.oAuth.clientId} = (
              (services.http.mkOauthConfig {
                inherit svcConfig config;
                oAuthCallbackUrl = "/accounts/oidc/kanidm/login/callback/";
              })
              // {
                preferShortUsername = true;
              }
            );
          };

          foxDen.services.postgresql = {
            enable = true;
            services = map (service: {
              database = "paperless";
              inherit service;
            }) paperlessServices;
          };

          services.paperless = {
            enable = true;
            address = "127.0.0.1";
            port = 8080;
            database.createLocally = false;
            settings = {
              PAPERLESS_URL = externalUrl;

              PAPERLESS_DBENGINE = "postgresql";
              PAPERLESS_DBHOST = "/run/postgresql";
              PAPERLESS_DBNAME = "paperless";
              PAPERLESS_DBUSER = "paperless";

              # Setting this stops the upstream module from wiring its own unix socket redis
              PAPERLESS_REDIS = "redis://127.0.0.1:6379";
            }
            // lib.optionalAttrs svcConfig.oAuth.enable {
              PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
              PAPERLESS_SOCIALACCOUNT_PROVIDERS = builtins.toJSON {
                openid_connect = {
                  OAUTH_PKCE_ENABLED = true;
                  APPS = [
                    {
                      provider_id = "kanidm";
                      name = "FoxDen";
                      client_id = svcConfig.oAuth.clientId;
                      secret = "";
                      settings = {
                        server_url = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}";
                        token_auth_method = "client_secret_post";
                      };
                    }
                  ];
                };
              };
              PAPERLESS_SOCIAL_AUTO_SIGNUP = true;
              PAPERLESS_DISABLE_REGULAR_LOGIN = true;
              PAPERLESS_REDIRECT_LOGIN_TO_SSO = true;
            };
          };

          systemd.services = lib.attrsets.genAttrs paperlessServices (_: {
            # Upstream passes store paths (fonts, NLTK data, PYTHONPATH) via environment
            confinement.fullUnit = true;
            requires = [ "redis-paperless.service" ];
            after = [ "redis-paperless.service" ];
            serviceConfig = {
              BindPaths = [
                cfg.dataDir
                cfg.mediaDir
                cfg.consumptionDir
              ];
            };
          });

          environment.persistence."/nix/persist/paperless" = {
            hideMounts = true;
            directories = [
              {
                directory = cfg.dataDir;
                inherit (cfg) user;
                group = config.users.users.${cfg.user}.group;
                mode = "u=rwx,g=,o=";
              }
            ];
          };
        }
      ]
    )
  );
}
