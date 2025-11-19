{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  mkDir = (
    dir: {
      directory = dir;
      user = "grafana";
      group = "grafana";
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.grafana;

  hostCfg = foxDenLib.hosts.getByName config svcConfig.host;
  primaryInterface = lib.lists.head (lib.attrsets.attrValues hostCfg.interfaces);
  hostName = primaryInterface.dns.fqdn;
  proto = if svcConfig.tls then "https" else "http";
in
{
  options.foxDen.services.grafana = services.http.mkOptions {
    svcName = "grafana";
    name = "Grafana monitoring server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "grafana";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-grafana";
        target = "proxy_pass http://127.0.0.1:3000;";
      }).config
      {
        foxDen.services.grafana.oAuth.overrideService = true;

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} =
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/login/generic_oauth";
            })
            // {
              preferShortUsername = true;
              claimMaps = {
                "grafana_role" = {
                  valuesByGroup = {
                    "superadmins" = [ "GrafanaAdmin" ];
                  };
                };
              };
            };
        };

        services.grafana = {
          dataDir = "/var/lib/grafana";
          enable = true;
          provision = {
            alerting = {
              contactPoints.path =
                config.lib.foxDen.sops.mkIfAvailable
                  config.sops.secrets."grafana-contact-points".path;
              policies.settings.policies = [
                {
                  group_by = [
                    "grafana_folder"
                    "alertname"
                  ];
                  group_interval = "5m";
                  group_wait = "30s";
                  orgId = 1;
                  receiver = "Telegram - FoxDen Home";
                  repeat_interval = "4h";
                }
              ];
              rules.path = ./alerts;
            };
            dashboards.settings.providers = [
              {
                options.path = ./dashboards;
              }
            ];
            datasources.settings = {
              prune = true;
              datasources = [
                {
                  access = "proxy";
                  name = "Prometheus";
                  type = "prometheus";
                  uid = "prometheus";
                  url = "http://prometheus.foxden.network:9090";
                }
              ];
            };
            enable = true;
          };
          settings = {
            "auth.generic_oauth" = lib.mkIf svcConfig.oAuth.enable {
              allow_assign_grafana_admin = true;
              allow_sign_up = true;
              api_url = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}/userinfo";
              auth_url = "https://auth.foxden.network/ui/oauth2";
              auto_login = true;
              client_id = svcConfig.oAuth.clientId;
              client_secret = "";
              email_attribute_path = "email";
              enabled = true;
              login_attribute_path = "preferred_username";
              name = "FoxDen";
              name_attribute_path = "name";
              role_attribute_path = "contains(grafana_role[*], 'GrafanaAdmin') && 'GrafanaAdmin' || contains(grafana_role[*], 'Admin') && 'Admin' || contains(grafana_role[*], 'Editor') && 'Editor' || 'Viewer'";
              role_attribute_strict = true;
              scopes = [
                "openid"
                "email"
                "profile"
              ];
              token_url = "https://auth.foxden.network/oauth2/token";
              use_pkce = true;
              use_refresh_token = false;
            };
            database = {
              host = config.foxDen.services.mysql.socketPath;
              name = "grafana";
              type = "mysql";
              user = "grafana";
            };
            security = {
              cookie_secure = svcConfig.tls;
              disable_initial_admin_creation = true;
            };
            server = {
              http_addr = "127.0.0.1";
              http_port = 3000;
              root_url = "${proto}://${hostName}";
            };
            smtp = {
              enabled = false;
            };
          };
        };

        sops.secrets.grafana = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "grafana";
          group = "grafana";
        };

        sops.secrets.grafana-contact-points = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "grafana";
          group = "grafana";
        };

        systemd.services.grafana = {
          restartTriggers = config.lib.foxDen.sops.mkIfAvailable [ config.sops.secrets.grafana.path ];

          confinement.packages = [
            pkgs.coreutils
          ];

          serviceConfig = {
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.grafana.path;
            StateDirectory = "grafana";
            BindReadOnlyPaths = config.lib.foxDen.sops.mkIfAvailable [
              config.sops.secrets."grafana-contact-points".path
            ];
          };
        };

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [ "grafana" ];
              service = "grafana";
            }
          ];
        };

        environment.persistence."/nix/persist/grafana" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/grafana")
          ];
        };
      }
    ]
  );
}
