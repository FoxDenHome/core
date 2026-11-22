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
  hostName = services.getFirstFQDN config svcConfig;
  proto = if svcConfig.tls.enable then "https" else "http";

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
    email = lib.mkOption {
      type = lib.types.str;
      description = "E-Mail for the service";
    };
  }
  // services.http.mkOptions {
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
        # Forgejo lacks Gitea's REQUIRE_SIGNIN_VIEW = expensive, so emulate it: anonymous
        # public clients get sent to the login page for the routes Gitea deems expensive
        # (routers/common/blockexpensive.go). Botnets solve Anubis once per IP, so it alone
        # doesn't keep them off these git-heavy pages.
        extraConfig =
          { defaultTarget, ... }:
          ''
            location ~ ^/(?!(?:user|login|api|admin|explore|org|notifications|assets|avatars|repo-avatars|attachments|-|\.well-known|\.within\.website)/)[^/]+/[^/]+/(?:(?:archive|blame|commit|commits|compare|src|wiki|activity|rss/branch)/|issues|pulls|graph) {
              auth_request /.foxden/forgejo-signed-in;
              ${pkgs.foxden-http-errors.passthru.nginxErrorPages (
                lib.filter (code: code != "401") (lib.attrNames pkgs.foxden-http-errors.passthru.httpStateMap)
              )}
              error_page 401 = @forgejo_login;
              ${defaultTarget}
            }

            location @forgejo_login {
              # This server sits behind Anubis on plain 127.0.0.1:9898
              absolute_redirect off;
              return 303 /user/login?redirect_to=$request_uri;
            }

            # 200 with a session (cheap unread notification count), 303 to /user/login without
            location = /.foxden/forgejo-signed-in {
              internal;
              if ($foxden_anubis_bypass) {
                return 204;
              }
              fastcgi_pass 127.0.0.1:3000;
              fastcgi_pass_request_body off;
              fastcgi_param REQUEST_METHOD GET;
              fastcgi_param REQUEST_URI /notifications/new;
              fastcgi_param QUERY_STRING "";
              fastcgi_param CONTENT_LENGTH "";
              fastcgi_param SERVER_PROTOCOL $server_protocol;
              fastcgi_param REMOTE_ADDR $remote_addr;
              fastcgi_param REMOTE_PORT $remote_port;
              fastcgi_param SERVER_NAME $server_name;
              fastcgi_param SERVER_PORT $server_port;
              fastcgi_intercept_errors on;
              error_page 301 302 303 307 308 = @forgejo_signed_out;
            }

            location @forgejo_signed_out {
              return 401;
            }
          '';
      }).config
      {
        foxDen.services.forgejo.oAuth.overrideService = true;

        # Scrapers flooding the web UI exhaust Forgejo's threads with git helper procs.
        # Non-browser clients (git, runners, API users) pass Anubis' default policy anyway,
        # so let git/LFS/API traffic skip it to keep pushes and uploads off the extra hop.
        foxDen.services.forgejo.anubis = {
          enable = true;
          default = true;
          bypassRoutes = [
            "~ ^/[^/]+/[^/]+/(info/refs|git-upload-pack|git-receive-pack|info/lfs/)"
            "/api/"
          ];
          # Anubis' default thresholds, one notch harder. Plain browsers land in moderate-suspicion,
          # whose stock difficulty 2 the 11/19 botnet solved for ~260k IPs.
          thresholds = [
            {
              name = "minimal-suspicion";
              expression = "weight <= 0";
              action = "ALLOW";
            }
            {
              name = "mild-suspicion";
              expression.all = [
                "weight > 0"
                "weight < 10"
              ];
              action = "CHALLENGE";
              challenge = {
                algorithm = "metarefresh";
                difficulty = 1;
              };
            }
            {
              name = "moderate-suspicion";
              expression.all = [
                "weight >= 10"
                "weight < 20"
              ];
              action = "CHALLENGE";
              challenge = {
                algorithm = "fast";
                difficulty = 4;
              };
            }
            {
              name = "mild-proof-of-work";
              expression.all = [
                "weight >= 20"
                "weight < 30"
              ];
              action = "CHALLENGE";
              challenge = {
                algorithm = "fast";
                difficulty = 5;
              };
            }
            {
              name = "extreme-suspicion";
              expression = "weight >= 30";
              action = "CHALLENGE";
              challenge = {
                algorithm = "fast";
                difficulty = 6;
              };
            }
          ];
        };

        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId} =
            (services.http.mkOauthConfig {
              inherit svcConfig config;
              oAuthCallbackUrl = "/user/oauth2/FoxDen/callback";
              oAuthExtraScopes = [
                "ssh_publickeys"
                "groups_name"
              ];
            })
            // {
              preferShortUsername = true;
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
            age = "1d";
            type = "tar.zst";
          };
          enable = true;
          lfs = {
            enable = true;
          };
          settings = {
            DEFAULT = {
              APP_NAME = "FoxDen Git";
              APP_SLOGAN = "Foxes are best animal";
            };
            server = {
              DOMAIN = hostName;
              HTTP_ADDR = "127.0.0.1";
              HTTP_PORT = 3000;
              PROTOCOL = "fcgi";
              ROOT_URL = "${proto}://${hostName}";
              START_SSH_SERVER = true;
              BUILTIN_SSH_SERVER_USER = "git";
            };
            mailer = {
              ENABLED = true;
              PROTOCOL = "smtp";
              SMTP_ADDR = config.lib.foxDen.mailerHost;
              SMTP_PORT = 2525;
              FROM = "FoxDen Git <${svcConfig.email}>";
            };
            service = {
              DISABLE_REGISTRATION = true;
            };
            indexer = {
              REPO_INDEXER_ENABLED = true;
            };
            session = {
              COOKIE_SECURE = svcConfig.tls.enable;
            };
            oauth2_client = {
              ENABLE_AUTO_REGISTRATION = true;
              OPENID_CONNECT_SCOPES = "openid email profile ssh_publickeys groups_name";
              REGISTER_EMAIL_CONFIRM = false;
            };
            repository = {
              # Archive generation was the most expensive request the 11/19 scrapers made (~2s each)
              DISABLE_DOWNLOAD_SOURCE_ARCHIVES = true;
            };
            "repository.pull-request" = {
              DEFAULT_MERGE_STYLE = "squash";
              DEFAULT_UPDATE_STYLE = "rebase";
            };
          };
          package = pkgs.forgejo;
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
              databases = [ "forgejo" ];
              service = "forgejo";
            }
            {
              databases = [ "forgejo" ];
              service = "forgejo-dump";
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
