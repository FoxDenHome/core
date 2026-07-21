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

  cfgJYaml = {
    single_circle_instance = true;
    is_user_creation_disabled = true;
    disable_password_auth = svcConfig.oAuth.enable;

    server = {
      port = 3010;
      cors_allow_origins = [
        externalUrl
        "capacitor://localhost"
        "http://localhost"
      ];
      serve_frontend = false;
      serve_swagger = true;
      public_host = externalUrl;
    };

    database = {
      type = "postgres";
      host = "/run/postgresql/";
      port = 5432;
      user = "donetick";
      name = "donetick";
      migration = true;
    };

    oauth2 =
      if svcConfig.oAuth.enable then
        {
          admin_groups = [ "superadmins" ];
          name = "FoxDen";
          client_id = svcConfig.oAuth.clientId;
          scopes = [
            "openid"
            "profile"
            "email"
            "groups_name"
          ];
          auth_url = "https://auth.foxden.network/ui/oauth2";
          token_url = "https://auth.foxden.network/oauth2/token";
          user_info_url = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}/userinfo";
          redirect_url = "${externalUrl}/auth/oauth2";
        }
      else
        { };
  };
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
        target = ''
          root /web;
          try_files $uri $uri/ /index.html;
        '';
        extraConfig =
          { proxyConfig, ... }:
          ''
            location = /api {
              return 308 $scheme://$http_host/api/;
            }
            location /api/ {
              proxy_pass http://127.0.0.1:3010;
              ${proxyConfig}
            }
          '';
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
              oAuthAbsoluteRedirectUrls = [
                "donetick://auth/oauth2"
              ];
              oAuthExtraScopes = [ "groups" ];
              oAuthExtraGroups = [ "superadmins" ];
            })
            // {
              allowInsecureClientDisablePkce = true;
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

        systemd.services.http-donetick = {
          serviceConfig = {
            BindReadOnlyPaths = [
              "${pkgs.donetick-frontend}/share/donetick-frontend:/web"
            ];
          };
        };

        systemd.services.donetick = {
          environment = {
            DONETICK_DISABLE_SIGNUP = "True";
            DT_ENV = "selfhosted";
          };

          serviceConfig = {
            StateDirectory = "donetick";
            User = "donetick";
            Group = "donetick";
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.donetick.path;
            WorkingDirectory = "/var/lib/donetick";
            ExecStartPre = [
              "${pkgs.writeShellScript "donetick-server-init.sh" ''
                ${pkgs.coreutils}/bin/mkdir -p /var/lib/donetick/config
                ${pkgs.coreutils}/bin/chmod 700 /var/lib/donetick /var/lib/donetick/config
                ${pkgs.coreutils}/bin/cp -fv ${builtins.toFile "config.json" (builtins.toJSON cfgJYaml)} /var/lib/donetick/config/selfhosted.yaml
              ''}"
            ];
            ExecStart = [ "${pkgs.donetick-server}/bin/donetick-server" ];
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
