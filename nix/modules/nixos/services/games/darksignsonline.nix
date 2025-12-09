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
          routes = [
            "= /create_account.php"
            "= /forgot_password.php"
          ];
        };

        systemd.tmpfiles.rules = [
          "D /run/darksignsonline 0750 root darksignsonline"
        ];

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
          };
          phpOptions = ''
            display_errors = On
            log_errors = Off
            sendmail_path = "${pkgs.msmtp}/bin/msmtp -C /tmp/msmtp.conf -t -i"
          '';
        };

        systemd.services.phpfpm-darksignsonline = {
          confinement.packages = with pkgs; [ msmtp ];
          path = with pkgs; [ msmtp ];

          serviceConfig = {
            BindReadOnlyPaths = [
              "${pkgs.darksignsonline-server}/www:/var/www"
            ];
            BindPaths = [
              "/run/darksignsonline"
            ];
            PrivateUsers = false;
            ExecStartPre = [
              "${pkgs.bash}/bin/bash ${pkgs.darksignsonline-server}/rootfs/bin/configure.sh darksignsonline:darksignsonline"
            ];
            Environment = [
              "DOMAIN=${svcConfig.domain}"
              "HTTP_MODE=${if svcConfig.tls.enable then "https" else "http"}"
              "TRUSTED_PROXIES=${lib.concatStringsSep " " config.foxDen.services.trustedProxies}"
              "SMTP_FROM=noreply@${svcConfig.domain}"
            ];
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.darksignsonline.path;
          };
        };

        systemd.services.tasks-darksignsonline = {
          after = [ "phpfpm-darksignsonline.service" ];
          wants = [ "phpfpm-darksignsonline.service" ];

          serviceConfig = {
            User = "darksignsonline";
            Group = "darksignsonline";
            BindReadOnlyPaths = [
              "/run/darksignsonline"
            ];
            Type = "simple";
            ExecStart = "${phpPkg}/bin/php ${pkgs.darksignsonline-server}/www/_tasks.php";
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
