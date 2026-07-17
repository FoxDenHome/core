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

  cfgJson = {
    "$schema" = "https://github.com/toeverything/affine/releases/latest/download/config.schema.json";
    server = {
      name = "FoxDen Docs";
      host = hostName;
      externalUrl = "${proto}://${hostName}";
      listenAddr = "127.0.0.1";
    };
    indexer = {
      enabled = false;
    };
    auth = {
      allowSignup = false;
      allowSignupForOauth = svcConfig.oAuth.enable;
      newAccountShareActionDelay = 3;
    };
    flags = {
      allowGuestDemoWorkspace = false;
    };
    websocket = {
      transports = [ "websocket" ];
    };
    worker = {
      allowedOrigin = [ hostName ];
    };
    oauth = {
      "providers.oidc" =
        if svcConfig.oAuth.enable then
          {
            args = { };
            issuer = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}";
            clientId = svcConfig.oAuth.clientId;
            clientSecret = svcConfig.oAuth.clientId;
          }
        else
          { };
    };
  };
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
          };

          serviceConfig = {
            StateDirectory = "affine";
            User = "affine";
            Group = "affine";
            ExecStart = [ "${pkgs.affine-server}/bin/affine-server" ];
            BindReadOnlyPaths = [
              "${builtins.toFile "config.json" (builtins.toJSON cfgJson)}:/var/lib/affine/.affine/config/config.json"
            ];
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
