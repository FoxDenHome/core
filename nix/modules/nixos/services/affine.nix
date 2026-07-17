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
  externalUrl = "${proto}://${hostName}";

  cfgJson = {
    "$schema" = "https://github.com/toeverything/affine/releases/latest/download/config.schema.json";
    server = {
      inherit externalUrl;
      name = "FoxDen Docs";
      host = hostName;
      https = svcConfig.tls.enable;
      listenAddr = "127.0.0.1";
    };
    mailer = {
      "SMTP.name" = hostName;
      "SMTP.sender" = "FoxDen Docs <docs@foxden.network>";
    };
    telemetry = {
      allowedOrigin = [ externalUrl ];
    };
    worker = {
      allowedOrigin = [ externalUrl ];
    };
    indexer =
      if svcConfig.indexer then
        {
          enabled = true;
          "provider.type" = "elasticsearch";
          "provider.endpoint" = "http://127.0.0.1:9200";
        }
      else
        {
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
  options.foxDen.services.affine = {
    indexer = lib.mkEnableOption "Enable opensearch dependency and indexer";
  }
  // services.http.mkOptions {
    name = "AFFiNE";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-affine";
        target = "proxy_pass http://127.0.0.1:3010;";
      }).config
      (lib.mkIf svcConfig.indexer
        (services.make {
          inherit svcConfig pkgs config;
          name = "affine-uds-proxy";
        }).config
      )
      (services.make {
        inherit svcConfig pkgs config;
        name = "affine";
      }).config
      (foxDenLib.services.redis.make {
        inherit pkgs config svcConfig;
        name = "affine";
      }).config
      {
        sops.secrets.affine = config.lib.foxDen.sops.mkIfAvailable { };

        foxDen.services.affine.oAuth.overrideService = true;
        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} = (
            services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/oauth/callback";
            }
          );
        };

        foxDen.services.opensearch = lib.mkIf svcConfig.indexer {
          enable = true;
          users.affine = {
            indexPatterns = [ "affine_*" ];
          };
          services = [
            "affine"
            "affine-uds-proxy"
          ];
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

        systemd.services.affine-uds-proxy = lib.mkIf svcConfig.indexer {
          before = [ "affine.service" ];

          serviceConfig = {
            User = "affine";
            Group = "affine";
            ExecStart = [
              "${pkgs.socat}/bin/socat TCP-LISTEN:9200,fork,bind=127.0.0.1,reuseaddr UNIX-CONNECT:${config.foxDen.services.opensearch.socketPath}"
            ];
          };
          wantedBy = [ "multi-user.target" ];
        };

        systemd.services.affine = {
          after = [ "redis-affine.service" ];
          requires = [ "redis-affine.service" ];

          environment = {
            DATABASE_URL = "postgres://affine@localhost/affine?host=/run/postgresql/";
            DEBUG_LOGGING = "false";
          };

          serviceConfig = {
            StateDirectory = "affine";
            User = "affine";
            Group = "affine";
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.affine.path;
            ExecStartPre = [
              "${pkgs.writeShellScript "affine-server-init.sh" ''
                ${pkgs.coreutils}/bin/mkdir -p /var/lib/affine/.affine/{config,storage}
                ${pkgs.coreutils}/bin/chmod 700 /var/lib/affine/.affine{,/config,/storage}
                ${pkgs.coreutils}/bin/cp -fv ${builtins.toFile "config.json" (builtins.toJSON cfgJson)} /var/lib/affine/.affine/config/config.json
              ''}"
            ];
            ExecStart = [ "${pkgs.affine-server}/bin/affine-server" ];
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
