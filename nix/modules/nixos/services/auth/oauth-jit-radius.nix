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
  proto = if svcConfig.tls.enable then "https" else "http";

  # Lets the VPN tray get credentials with the Kerberos ticket it already has.
  keytabName = "oauth-jit-radius";
  keytab = config.foxDen.kerberos.keytabs.${keytabName};
  servicePrincipal = "HTTP/${hostName}";

  # The groups Kanidm would report in userinfo, from its provisioning on
  # this host: user -> [ group ].
  kanidmGroups = lib.foldlAttrs (
    acc: group: g:
    if g.present then
      lib.foldl' (acc: user: acc // { ${user} = (acc.${user} or [ ]) ++ [ group ]; }) acc g.members
    else
      acc
  ) { } config.services.kanidm.provision.groups;

  configObj = {
    matchers = [
      {
        subnets = [ "10.1.12.1/32" ];
        secret = "$\{RADIUS_SECRET_SUPERMICRO}";
        mapper = "supermicro";
      }
      {
        subnets = [ "10.1.11.2/32" ];
        secret = "$\{RADIUS_SECRET_EATON}";
        mapper = "eaton";
      }
      {
        subnets = [
          "10.1.11.3/32"
          "10.1.11.4/32"
        ];
        secret = "$\{RADIUS_SECRET_CYBERPOWER}";
        mapper = "cyberpower";
      }
      {
        subnets = [
          "10.1.13.2/32"
        ];
        secret = "$\{RADIUS_SECRET_TRIPPLITE}";
        mapper = "tripplite";
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
        "groups_name"
      ];
      client_id = svcConfig.oAuth.clientId;
      client_secret = "PKCE";
      server_addr = "127.0.0.1:1444";
      admin_group = "superadmins";
      viewer_group = "";
    };
    kerberos = {
      keytab = "$\{CREDENTIALS_DIRECTORY}/keytab";
      principal = servicePrincipal;
      realm = config.foxDen.kerberos.realm;
      groups = kanidmGroups;
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

        foxDen.kerberos = {
          enable = true;
          keytabs.${keytabName}.principals = [ servicePrincipal ];
        };

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} =
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/redirect";
            })
            // {
              preferShortUsername = true;
              scopeMaps.superadmins = [
                "preferred_username"
                "email"
                "openid"
                "profile"
                "groups_name"
              ];
            };
        };

        systemd.services.oauth-jit-radius = {
          requires = [ keytab.unit ];
          after = [ keytab.unit ];

          confinement.packages = [
            pkgs.oauth-jit-radius
          ];

          serviceConfig = {
            DynamicUser = true;

            BindReadOnlyPaths = [
              "${configFile}:/etc/oauth-jit-radius/config.yml"
            ];

            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.oauth-jit-radius.path;
            LoadCredential = "keytab:${keytab.path}";
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
