{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.foxcaves;
in
{
  options.foxDen.services.foxcaves = {
    storageDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/foxcaves/storage";
    };
    email = lib.mkOption {
      type = lib.types.str;
      description = "E-Mail for the service";
    };
  }
  // services.mkOptions {
    name = "foxCaves";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "foxcaves";
      }).config
      (foxDenLib.services.redis.make {
        inherit pkgs config svcConfig;
        name = "foxcaves";
      }).config
      {
        environment.etc."foxcaves/production.lua".text = ''
          return {
            redis = {
              host = "127.0.0.1",
              port = 6379,
              password = nil,
            },
            mysql = {
              host = nil,
              port = nil,
              path = os.getenv("MYSQL_SOCKET"),
              user = os.getenv("MYSQL_USERNAME"),
              password = "",
              database = os.getenv("MYSQL_DATABASE"),
            },
            email = {
              host = "mailer.foxden.network",
              ssl = false,
              port = 2525,
              username = "",
              password = "",
              from = "foxCaves <${svcConfig.email}>",
              admin_email = "foxcaves@doridian.net",
            },
            files = {
              thumbnail_max_size = 50 * 1024 * 1024,
            },
            app = {
              disable_email_confirmation = false,
              enable_testing_routes = false,
              require_user_approval = true,
              expiry_check_period = 60 * 15, -- 15 minutes
              executor = "tracefile",
            },
            totp = {
              max_past = 1,
              max_future = 1,
              secret_bytes = 20,
              issuer = "foxCaves"
            },
            captcha = {
              registration = true,
              login = false,
              forgot_password = false,
              resend_activation = false,
            },
            storage = {
              default = "fs",
              backends = {
                fs = {
                  driver = "local",
                  root_folder = "/var/lib/foxcaves/storage",
                  chunk_size = 8192,
                },
              },
            },
            cookies = {
              path = "/",
              samesite = "Strict",
              httponly = true,
              secure = true,
            },
            http = {
              app_url = "https://foxcav.es",
              cdn_url = "https://f0x.es",
              enable_acme = true,
              redirect_www = true,
              upstream_ips = {"10.99.10.1/32"},
            },
          }
        '';

        users.users.foxcaves = {
          isSystemUser = true;
          home = "/var/lib/foxcaves";
          group = "foxcaves";
        };
        users.groups.foxcaves = { };

        foxDen.hosts.hosts.${svcConfig.host}.webservice.enable = true;

        systemd.services.foxcaves = {
          after = [ "redis-foxcaves.service" ];
          requires = [ "redis-foxcaves.service" ];

          serviceConfig = {
            ExecStart = [ "${pkgs.foxCaves}/bin/foxCaves" ];

            User = "foxcaves";
            Group = "foxcaves";
            DynamicUser = false;

            Environment = [
              "ENVIRONMENT=production"
            ];
            BindReadOnlyPaths = foxDenLib.services.mkEtcPaths [
              "foxcaves/production.lua"
            ];
            BindPaths = [
              "-${svcConfig.storageDir}"
            ];
            StateDirectory = "foxcaves";
          };

          wantedBy = [ "multi-user.target" ];
        };

        foxDen.services.mysql = {
          enable = true;
          services = [
            {
              databases = [ "foxcaves" ];
              service = "foxcaves";
            }
          ];
        };

        environment.persistence."/nix/persist/foxcaves" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/foxcaves";
              user = "foxcaves";
              group = "foxcaves";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
