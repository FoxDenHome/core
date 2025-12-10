{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  phpPkg = pkgs.php84;
  svcConfig = config.foxDen.services.darksignsonline;

  bindReadOnlyPaths = lib.mkMerge [
    [
      "${pkgs.darksignsonline-server}/www:/var/www"
    ]
    (config.lib.foxDen.sops.mkIfAvailable [
      "${config.sops.secrets.darksignsonline-config.path}:/run/darksignsonline/dso-config.php"
    ])
  ];
in
{
  options.foxDen.services.darksignsonline = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Domain name for the service";
    };
    tls = lib.mkEnableOption "Enable TLS for the service";
  }
  // services.http.mkOptions {
    svcName = "darksignsonline";
    name = "Dark Signs Online";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit svcConfig pkgs config;
        name = "phpfpm-darksignsonline";
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
          index index.php index.htm index.html;
        '';
        extraConfig =
          { package, ... }:
          ''
            root /var/www;
            location ~ \.php$ {
              fastcgi_index index.php;
              include ${package}/conf/fastcgi_params;
              fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
              fastcgi_param SCRIPT_NAME $fastcgi_script_name;
              fastcgi_pass unix:${config.services.phpfpm.pools.darksignsonline.socket};
            }
          '';
      }).config
      {
        sops.secrets.darksignsonline-config = config.lib.foxDen.sops.mkIfAvailable {
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
          routes = [
            "= /create_account.php"
            "= /forgot_password.php"
          ];
        };

        systemd.services.http-darksignsonline = {
          serviceConfig = {
            User = "darksignsonline";
            Group = "darksignsonline";

            BindReadOnlyPaths = [
              "${pkgs.darksignsonline-server}/www:/var/www"
              "/run/phpfpm"
            ];
          };
        };

        services.phpfpm.settings = {
          "error_log" = lib.mkForce "/proc/self/fd/2";
          "log_buffering" = "no";
          "log_level" = "error";
        };

        services.phpfpm.pools.darksignsonline = {
          user = "darksignsonline";
          group = "darksignsonline";
          phpPackage = phpPkg;
          settings = {
            "pm" = "dynamic";
            "pm.max_children" = 5;
            "pm.start_servers" = 2;
            "pm.min_spare_servers" = 1;
            "pm.max_spare_servers" = 3;
            "listen.owner" = "darksignsonline";
            "listen.group" = "darksignsonline";
            "catch_workers_output" = "yes";
            "decorate_workers_output" = "no";
          };
          phpOptions = ''
            display_errors = Off
            log_errors = On
            fastcgi.logging = Off
          '';
        };

        systemd.services.phpfpm-darksignsonline = {
          serviceConfig = {
            BindReadOnlyPaths = bindReadOnlyPaths;
            PrivateUsers = false;
          };
        };

        systemd.services.tasks-darksignsonline = {
          serviceConfig = {
            User = "darksignsonline";
            Group = "darksignsonline";
            Type = "simple";
            ExecStart = "${phpPkg}/bin/php /var/www/_tasks.php";
            Restart = "no";
            BindReadOnlyPaths = bindReadOnlyPaths;
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
              service = "phpfpm-darksignsonline";
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
