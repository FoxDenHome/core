{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.darksignsonline;

  # The game server answers every `/<name>.php` and `/api/<name>.php`; nginx
  # serves the rest. It shares the host's network namespace with nginx.
  listen = "127.0.0.1:8000";
  server = "${pkgs.darksignsonline-server}/bin/darksignsonline-server";
in
{
  options.foxDen.services.darksignsonline = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Domain name for the service";
    };
    email = lib.mkOption {
      type = lib.types.str;
      description = "E-Mail for the service";
    };
    tls = lib.mkEnableOption "Enable TLS for the service";
  }
  // services.http.mkOptions {
    name = "Dark Signs Online";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit svcConfig pkgs config;
        name = "darksignsonline";
      }).config
      (foxDenLib.services.make {
        inherit svcConfig pkgs config;
        name = "tasks-darksignsonline";
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        dynamicUser = false;
        name = "http-darksignsonline";
        target = ''
          index index.html;
        '';
        extraConfig =
          {
            headerConfig,
            securityHeaderConfig,
            ...
          }:
          ''
            root /var/www/darksignsonline;
            location = /game {
              return 308 /game/;
            }
            location /game/ {
              ${securityHeaderConfig}
              add_header Cross-Origin-Opener-Policy "same-origin" always;
              add_header Cross-Origin-Embedder-Policy "require-corp" always;
              add_header Cache-Control "public, max-age=31536000, immutable" always;
            }
            location = /game/index.html {
              ${headerConfig}
              add_header Cross-Origin-Opener-Policy "same-origin" always;
              add_header Cross-Origin-Embedder-Policy "require-corp" always;
            }
            location = /game/ {
              ${headerConfig}
              add_header Cross-Origin-Opener-Policy "same-origin" always;
              add_header Cross-Origin-Embedder-Policy "require-corp" always;
            }
            location = / {
              rewrite ^ /index.php last;
            }
            location ~ ^/(api/)?[a-z0-9_]+\.php$ {
              proxy_pass http://${listen}$uri$is_args$args;
              proxy_set_header X-Real-IP $remote_addr;
            }
          '';
      }).config
      {
        sops.secrets.darksignsonline = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "darksignsonline";
          group = "darksignsonline";
        };

        users.users.darksignsonline = {
          isSystemUser = true;
          group = "darksignsonline";
        };
        users.groups.darksignsonline = { };

        foxDen.services.darksignsonline.anubis = {
          enable = true;
          customBotPolicy = {
            bots = [
              {
                name = "catch-all-challenge";
                path_regex = ".*";
                action = "CHALLENGE";
                challenge = {
                  algorithm = "fast";
                  difficulty = 6;
                };
              }
            ];
          };
          routes = [
            "= /create_account.php"
            "= /forgot_password.php"
          ];
        };

        systemd.services.http-darksignsonline = {
          unitConfig = {
            After = [ "darksignsonline.service" ];
            Wants = [ "darksignsonline.service" ];
          };

          serviceConfig = {
            User = "darksignsonline";
            Group = "darksignsonline";

            BindReadOnlyPaths = [
              "${pkgs.darksignsonline}/var/www/darksignsonline:/var/www/darksignsonline"
            ];
          };
        };

        # The database settings come from foxDen.services.mysql below, the
        # JWT keys (JWT_PRIVATE_KEY, JWT_PUBLIC_KEY, base64 PEM) from sops.
        systemd.services.darksignsonline = {
          environment = {
            DSO_LISTEN = listen;
            SMTP_HOST = config.lib.foxDen.mailerHost;
            SMTP_PORT = "2525";
            SMTP_FROM = svcConfig.email;
          };

          serviceConfig = {
            User = "darksignsonline";
            Group = "darksignsonline";

            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.darksignsonline.path;

            Type = "exec";
            ExecStart = server;
            Restart = "always";
          };

          wantedBy = [ "multi-user.target" ];
        };

        systemd.services.tasks-darksignsonline = {
          serviceConfig = {
            User = "darksignsonline";
            Group = "darksignsonline";
            Type = "simple";
            ExecStart = "${server} tasks";
            Restart = "no";
          };
        };

        systemd.timers.tasks-darksignsonline = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "10min";
            OnUnitInactiveSec = "15min";
          };
        };

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [ "darksignsonline" ];
              service = "darksignsonline";
              user = "darksignsonline";
            }
            {
              databases = [ "darksignsonline" ];
              service = "tasks-darksignsonline";
              user = "darksignsonline";
            }
          ];
        };
      }
    ]
  );
}
