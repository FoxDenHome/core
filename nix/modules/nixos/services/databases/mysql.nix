{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.mysql;

  serviceType =
    with lib.types;
    submodule {
      options = {
        databases = lib.mkOption {
          type = listOf str;
          description = "List of databases to ensure exist for this user";
        };
        service = lib.mkOption {
          type = str;
          description = "Name of the systemd service needing to connect";
        };
        user = lib.mkOption {
          type = nullOr str;
          description = "User the service runs as";
          default = null;
        };
      };
    };

  mkSvcUser =
    svc:
    if svc.user != null then svc.user else config.systemd.services.${svc.service}.serviceConfig.User;
in
{
  options.foxDen.services.mysql =
    with lib.types;
    services.mkOptions {
      svcName = "mysql";
      name = "MySQL";
    }
    // {
      services = lib.mkOption {
        type = listOf serviceType;
        default = [ ];
        description = "List of systemd services connecting to MySQL";
      };
      socketPath = lib.mkOption {
        type = str;
        description = "Path to MySQL socket (read-only)";
      };
    };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "mysql";
        inherit svcConfig pkgs config;
      }).config
      {
        foxDen.services.mysql = {
          host = "mysql";
          socketPath = lib.mkForce "/run/mysqld/mysqld.sock";
        };

        foxDen.hosts.hosts = {
          mysql.interfaces = { };
        };

        services.mysql = {
          enable = true;
          package = pkgs.mariadb;
          settings = {
            mysqld = {
              skip-networking = true;
            };
          };
          ensureDatabases = lib.flatten (map (svc: svc.databases) svcConfig.services);
          ensureUsers = map (svc: {
            name = mkSvcUser svc;
            ensurePermissions = lib.attrsets.listToAttrs (
              map (dbName: {
                name = "${dbName}.*";
                value = "ALL PRIVILEGES";
              }) svc.databases
            );
          }) svcConfig.services;
        };

        systemd.services.mysql = {
          confinement.packages = [
            pkgs.gnused
          ];
          serviceConfig = {
            PrivateUsers = false;
            StateDirectory = "mysql";
            BindReadOnlyPaths = [
              "/etc/my.cnf"
            ];
          };
        };

        environment.persistence."/nix/persist/mysql" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/mysql";
              user = config.services.mysql.user;
              group = config.services.mysql.group;
              mode = "u=rwx,g=rx,o=";
            }
          ];
        };
      }
      {
        systemd.services = lib.attrsets.listToAttrs (
          map (mySvc: {
            name = mySvc.service;
            value = {
              requires = [ "mysql.service" ];
              after = [ "mysql.service" ];
              serviceConfig = {
                BindReadOnlyPaths = [
                  "/run/mysqld"
                ];
                Environment = [
                  "MYSQL_SOCKET=${config.foxDen.services.mysql.socketPath}"
                  "MYSQL_DATABASE=${builtins.head mySvc.databases}"
                  "MYSQL_USERNAME=${mkSvcUser mySvc}"
                ];
              };
            };
          }) svcConfig.services
        );
      }
    ]
  );
}
