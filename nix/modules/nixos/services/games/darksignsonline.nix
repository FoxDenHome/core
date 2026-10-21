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

  # The game server is the whole site: the API, the account pages, the static
  # files and the browser client, with the headers the client needs. nginx is
  # only TLS and Anubis in front of it. It shares the host's network namespace
  # with nginx, so nginx's X-Real-IP comes from loopback, which the server
  # trusts by default.
  listen = "127.0.0.1:8000";
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
      (services.http.make {
        inherit svcConfig pkgs config;
        dynamicUser = false;
        name = "http-darksignsonline";
        # The server sends its own X-Content-Type-Options and X-Frame-Options
        # (and its own Cache-Control, which nginx keeps); nginx adds these two
        # for every response, so drop the server's copies rather than
        # sending each twice.
        target = ''
          proxy_pass http://${listen};
          proxy_hide_header X-Content-Type-Options;
          proxy_hide_header X-Frame-Options;
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
            ExecStart = lib.getExe pkgs.darksignsonline;
            Restart = "always";
          };

          wantedBy = [ "multi-user.target" ];
        };

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [ "darksignsonline" ];
              service = "darksignsonline";
              user = "darksignsonline";
            }
          ];
        };
      }
    ]
  );
}
