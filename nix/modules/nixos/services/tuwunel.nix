{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.tuwunel;
  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";
in
{
  options.foxDen.services.tuwunel = {
    serverName = lib.mkOption {
      type = lib.types.str;
      description = "Matrix server name";
    };
  }
  // services.http.mkOptions {
    name = "Tuwunel Matrix";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "tuwunel";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-tuwunel";
        target = "proxy_pass http://127.0.0.1:6167;";
      }).config
      {
        foxDen.services.paperless.oAuth.overrideService = true;
        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} = (
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/_matrix/client/unstable/login/sso/callback/${svcConfig.oAuth.clientId}";
            })
            // {
              preferShortUsername = true;
            }
          );
        };

        services.matrix-tuwunel = {
          enable = true;
          stateDirectory = "tuwunel";
          settings = {
            global = {
              address = [ "127.0.0.1" ];
              port = [ 6167 ];
              server_name = svcConfig.serverName;
              well_known = {
                client = "${proto}://${hostName}";
                server = "${hostName}:443";
              };
              identity_provider = [
                {
                  brand = "Kanidm";
                  client_id = svcConfig.oAuth.clientId;
                  client_secret = svcConfig.oAuth.clientId;
                  issuer_url = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}";
                  default = true;
                }
              ];
            };
          };
        };

        systemd.services.tuwunel = {
          serviceConfig = {
            BindReadOnlyPaths = [
              config.systemd.services.tuwunel.environment.TUWUNEL_CONFIG
            ];
          };
        };
      }
    ]
  );
}
