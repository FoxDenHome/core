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
      user = config.services.forgejo.user;
      group = config.services.forgejo.group;
      mode = "u=rwx,g=,o=";
    }
  );

  defaultDataDir = "/var/lib/forgejo";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);

  svcConfig = config.foxDen.services.forgejo;

  hostCfg = foxDenLib.hosts.getByName config svcConfig.host;
  primaryInterface = lib.lists.head (lib.attrsets.attrValues hostCfg.interfaces);
  hostName = foxDenLib.global.dns.mkHost primaryInterface.dns;
  proto = if svcConfig.tls then "https" else "http";

  baseServiceConfig = {
    BindPaths = [ config.services.forgejo.stateDir ];
    BindReadOnlyPaths = [
      "/usr/bin/env"
    ];
    StateDirectory = ifDefaultData "forgejo";
  };

  baseSystemdConfig = {
    requires = [ "forgejo-pre.service" ];
    after = [ "forgejo-pre.service" ];
    serviceConfig = baseServiceConfig;

    confinement.packages = [
      config.services.forgejo.package
      pkgs.coreutils
    ];
    path = [
      pkgs.coreutils
    ];
  };
in
{
  options.foxDen.services.forgejo = {
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = defaultDataDir;
      description = "Directory to store git data";
    };
  }
  // services.http.mkOptions {
    svcName = "forgejo";
    name = "Forgejo git server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "forgejo-pre";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "forgejo";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "forgejo-secrets";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "forgejo-dump";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-forgejo";
        target = "fastcgi_pass 127.0.0.1:3000;";
      }).config
      {
        foxDen.services.forgejo.oAuth.overrideService = true;

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} =
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/user/oauth2/FoxDen/callback";
            })
            // {
              preferShortUsername = true;
              claimMaps = {
                "git_group" = {
                  valuesByGroup = {
                    "superadmins" = [ "admin" ];
                  };
                };
              };
            };
        };

        services.forgejo = {
          database = {
            createDatabase = false;
            name = "forgejo";
            socket = config.foxDen.services.mysql.socketPath;
            type = "mysql";
            user = "forgejo";
          };
          dump = {
            enable = true;
            age = "90d";
            type = "tar.zst";
          };
          enable = true;
          lfs = {
            enable = true;
          };
          settings = {
            server = {
              DOMAIN = hostName;
              HTTP_ADDR = "127.0.0.1";
              HTTP_PORT = 3000;
              PROTOCOL = "fcgi";
              ROOT_URL = "${proto}://${hostName}";
              START_SSH_SERVER = true;
              BUILTIN_SSH_SERVER_USER = "git";
            };
            service = {
              DISABLE_REGISTRATION = true;
            };
            session = {
              COOKIE_SECURE = svcConfig.tls;
            };
            oauth2_client = {
              ENABLE_AUTO_REGISTRATION = true;
              OPENID_CONNECT_SCOPES = "openid email profile";
              REGISTER_EMAIL_CONFIRM = false;
            };
          };
          stateDir = svcConfig.dataDir;
        };

        systemd.services.forgejo-pre = {
          serviceConfig = baseServiceConfig // {
            ExecStart = [
              "${pkgs.coreutils}/bin/mkdir -p ${config.services.forgejo.stateDir}/data ${config.services.forgejo.stateDir}/conf ${config.services.forgejo.stateDir}/log ${config.services.forgejo.stateDir}/.ssh  ${config.services.forgejo.customDir}/conf ${config.services.forgejo.dump.backupDir} ${config.services.forgejo.lfs.contentDir} ${config.services.forgejo.repositoryRoot}"
            ];

            User = config.services.forgejo.user;
            Group = config.services.forgejo.group;

            Restart = "no";
            Type = "oneshot";
            RemainAfterExit = true;
          };

          wantedBy = [ "multi-user.target" ];
        };

        systemd.services.forgejo = baseSystemdConfig;
        systemd.services.forgejo-secrets = lib.mkMerge [
          baseSystemdConfig
          {
            serviceConfig = {
              Restart = "no";
            };
          }
        ];
        systemd.services.forgejo-dump = lib.mkMerge [
          baseSystemdConfig
          {
            serviceConfig = {
              Restart = "no";
            };
          }
        ];

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              name = "forgejo";
              targetService = "forgejo";
            }
          ];
        };

        environment.persistence."/nix/persist/forgejo" = ifDefaultData {
          hideMounts = true;
          directories = [
            (mkDir defaultDataDir)
          ];
        };
      }
    ]
  );
}
