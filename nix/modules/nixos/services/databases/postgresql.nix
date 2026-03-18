{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.postgresql;

  serviceType =
    with lib.types;
    submodule {
      options = {
        database = lib.mkOption {
          description = "Name of the database";
          type = str;
        };
        service = lib.mkOption {
          description = "Name of the systemd service needing to connect";
          type = str;
        };
      };
    };

  mkSvcUser = svc: config.systemd.services.${svc.service}.serviceConfig.User;
in
{
  options.foxDen.services.postgresql =
    with lib.types;
    services.mkOptions {
      svcName = "postgresql";
      name = "PostgreSQL";
    }
    // {
      services = lib.mkOption {
        type = listOf serviceType;
        default = [ ];
        description = "List of systemd services connecting to PostgreSQL";
      };
      socketPath = lib.mkOption {
        type = str;
        description = "Path to PostgreSQL socket (read-only)";
      };
    };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "postgresql";
        inherit svcConfig pkgs config;
      }).config
      {
        foxDen.services.postgresql = {
          host = "postgresql";
          socketPath = lib.mkForce "/run/postgresql/.s.PGSQL.5432";
        };

        foxDen.hosts.hosts = {
          postgresql.interfaces = { };
        };

        services.postgresql = {
          enable = true;
          package = pkgs.postgresql_16_jit;
          enableTCPIP = false;
          ensureDatabases = map (svc: svc.database) svcConfig.services;
          ensureUsers = map (svc: {
            name = svc.database;
            ensureDBOwnership = true;
          }) svcConfig.services;
          identMap = ''
            postgres root postgres
          ''
          + lib.concatStringsSep "\n" (
            map (svc: ''
              postgres ${mkSvcUser svc} ${svc.database}
            '') svcConfig.services
          );
        };

        systemd.services.postgresql = {
          confinement.packages = [
            pkgs.gnugrep
          ];
          path = [
            pkgs.gnugrep
          ];

          serviceConfig = {
            PrivateUsers = false;
          };
        };

        environment.persistence."/nix/persist/postgresql" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/postgresql";
              user = "postgres";
              group = "postgres";
              mode = "u=rwx,g=rx,o=";
            }
          ];
        };
      }
      {
        systemd.services = lib.attrsets.listToAttrs (
          map (pgSvc: {
            name = pgSvc.service;
            value = {
              requires = [ "postgresql.service" ];
              after = [ "postgresql.service" ];
              serviceConfig = {
                BindReadOnlyPaths = [
                  "/run/postgresql"
                ];
                Environment = [
                  "POSTGRESQL_SOCKET=${config.foxDen.services.postgresql.socketPath}"
                  "POSTGRESQL_DATABASE=${pgSvc.database}"
                  "POSTGRESQL_USERNAME=${pgSvc.database}"
                ];
              };
            };
          }) svcConfig.services
        );
      }
    ]
  );
}
