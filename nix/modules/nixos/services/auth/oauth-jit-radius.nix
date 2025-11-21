{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.oauth-jit-radius;

  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls then "https" else "http";

  configObj = {
    matchers = [
      {
        subnets = [
          "10.2.1.1/32"
          "10.2.1.2/32"
        ];
        secret = "$\{RADIUS_SECRET_MIKROTIK}";
        mapper = "mikrotik";
      }
      {
        subnets = [ "10.1.12.1/32" ];
        secret = "$\{RADIUS_SECRET_SUPERMICRO}";
        mapper = "supermicro";
      }
      {
        subnets = [ "10.1.11.2/32" ];
        secret = "$\{RADIUS_SECRET_APCUPS}";
        mapper = "apc";
      }
      {
        subnets = [ "10.1.11.3/32" ];
        secret = "$\{RADIUS_SECRET_CYBERPOWER}";
        mapper = "cyberpower";
      }
    ];
    radius = {
      password_expiry = "1h";
    };
    oauth = {
      userinfo_url = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}/userinfo";
      token_url = "https://auth.foxden.network/oauth2/token";
      auth_url = "https://auth.foxden.network/ui/oauth2";
      redirect_url = "${proto}://${hostName}/redirect";
      scopes = [
        "openid"
        "profile"
      ];
      client_id = svcConfig.oAuth.clientId;
      client_secret = "$\{OAUTH_CLIENT_SECRET}";
      server_addr = "127.0.0.1:1444";
    };
  };

  configFile = pkgs.writers.writeYAML "config.yml" configObj;
in
{
  options.foxDen.services.oauth-jit-radius = {
    clientId = lib.mkOption {
      type = lib.types.str;
      default = "radius";
      description = "OAuth Client ID for oauth-jit-radius";
    };
  }
  // (services.http.mkOptions {
    svcName = "oauth-jit-radius";
    name = "OAuthJITRadius";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "oauth-jit-radius";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-oauth-jit-radius";
        target = "proxy_pass http://127.0.0.1:1444;";
      }).config
      {
        foxDen.services.oauth-jit-radius.oAuth.overrideService = true;

        sops.secrets.oauth-jit-radius = config.lib.foxDen.sops.mkIfAvailable { };

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} =
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/redirect";
            })
            // {
              preferShortUsername = true;
              claimMaps = {
                "apc_service_type" = {
                  valuesByGroup = {
                    "superadmins" = [ "admin" ];
                  };
                };
                "cyberpower_service_type" = {
                  valuesByGroup = {
                    "superadmins" = [ "admin" ];
                  };
                };
                "mikrotik_group" = {
                  valuesByGroup = {
                    "superadmins" = [ "full" ];
                  };
                };
                "supermicro_permissions" = {
                  valuesByGroup = {
                    "superadmins" = [ "administrator" ];
                  };
                };
              };
              scopeMaps.superadmins = [
                "preferred_username"
                "email"
                "openid"
                "profile"
              ];
            };
        };

        systemd.services.oauth-jit-radius = {
          confinement.packages = [
            pkgs.oauth-jit-radius
          ];

          serviceConfig = {
            DynamicUser = true;

            BindReadOnlyPaths = [
              "${configFile}:/etc/oauth-jit-radius/config.yml"
            ];

            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.oauth-jit-radius.path;
            WorkingDirectory = "/etc/oauth-jit-radius";

            Type = "simple";
            ExecStart = [ "${pkgs.oauth-jit-radius}/bin/oauth-jit-radius" ];
            StateDirectory = "oauth-jit-radius";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
