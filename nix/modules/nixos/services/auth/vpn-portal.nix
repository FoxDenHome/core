{
  foxDenLib,
  pkgs,
  lib,
  config,
  kerberos,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.vpn-portal;

  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";
  port = 1446;
  pkinitCaKeySecret = "foxden-vpn-portal-pkinit-ca";

  configFile = pkgs.writers.writeJSON "config.json" {
    listen = "127.0.0.1:${toString port}";
    public_url = "${proto}://${hostName}";
    oidc = {
      issuer = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}";
      client_id = svcConfig.oAuth.clientId;
    };
    # The first router is the source of truth, the others mirror it
    routers = map (address: {
      inherit address;
      username = "vpn-portal";
    }) svcConfig.routers;
    fastly = {
      service_id = svcConfig.fastlyServiceId;
      dictionary = "vpn_peers";
    };
    # Shares are handed to devices with their configuration.
    vpn.smb = kerberos.smbServers;
    # Kerberos client certificates for registered devices' owners (PKINIT).
    pkinit = {
      realm = config.foxDen.kerberos.realm;
      ca_cert = "${../../../../files/kerberos/pkinit-ca.pem}";
      ca_key = lib.optionalString config.foxDen.sops.available "/run/credentials/foxden-vpn-portal.service/pkinit-ca-key";
      validity = "24h";
    };
  };
in
{
  options.foxDen.services.vpn-portal = {
    routers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "router.foxden.network:8728"
        "router-backup.foxden.network:8728"
      ];
      description = "RouterOS API endpoints; the first one is authoritative";
    };
    fastlyServiceId = lib.mkOption {
      type = lib.types.str;
      default = "zl8wAY4UkFBVdrAzNU5t06";
      description = "Fastly service serving cdn.foxden.network";
    };
    oAuthGroup = lib.mkOption {
      type = lib.types.str;
      default = "login-users";
      description = "Kanidm group allowed to manage their VPN devices";
    };
  }
  // (services.http.mkOptions {
    name = "VPN portal";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "foxden-vpn-portal";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-foxden-vpn-portal";
        target = "proxy_pass http://127.0.0.1:${toString port};";
      }).config
      {
        foxDen.services.vpn-portal.oAuth.overrideService = true;

        # ROUTEROS_PASSWORD, FASTLY_API_TOKEN, SESSION_SECRET
        sops.secrets.foxden-vpn-portal = config.lib.foxDen.sops.mkIfAvailable { };
        sops.secrets.${pkinitCaKeySecret} = config.lib.foxDen.sops.mkIfAvailable { };

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} =
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              inherit (svcConfig) oAuthGroup;
            })
            // {
              preferShortUsername = true;
            };
        };

        systemd.services.foxden-vpn-portal = {
          confinement.packages = [
            pkgs.foxden-vpn
            configFile # and the files it names, like the PKINIT CA
          ];

          serviceConfig = {
            DynamicUser = true;
            BindReadOnlyPaths = [
              "${configFile}:/etc/foxden-vpn-portal/config.json"
            ];
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.foxden-vpn-portal.path;
            LoadCredential = config.lib.foxDen.sops.mkIfAvailable "pkinit-ca-key:${
              config.sops.secrets.${pkinitCaKeySecret}.path
            }";
            Type = "simple";
            ExecStart = [ "${pkgs.foxden-vpn}/bin/foxden-vpn-portal" ];
            Restart = "always";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
