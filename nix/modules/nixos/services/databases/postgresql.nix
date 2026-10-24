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

  groupSocketType =
    with lib.types;
    submodule {
      options = {
        database = lib.mkOption {
          description = "Name of the database (also used as role and proxy user name)";
          type = str;
        };
        group = lib.mkOption {
          description = "Unix group (name or GID) allowed to connect";
          type = either str int;
        };
      };
    };

  mkSvcUser = svc: config.systemd.services.${svc.service}.serviceConfig.User;
  mkGroupSocketDir = gs: "/run/postgresql-${gs.database}";
in
{
  options.foxDen.services.postgresql =
    with lib.types;
    services.mkOptions {
      name = "PostgreSQL";
    }
    // {
      services = lib.mkOption {
        type = listOf serviceType;
        default = [ ];
        description = "List of systemd services connecting to PostgreSQL";
      };
      groupSockets = lib.mkOption {
        type = listOf groupSocketType;
        default = [ ];
        description = ''
          Databases exposed to members of a Unix group via a proxied socket at
          /run/postgresql-<database>/.s.PGSQL.5432. Connections reach PostgreSQL
          as the <database> user, so access is decided by the socket's group.
        '';
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
          ensureDatabases = map (svc: svc.database) (svcConfig.services ++ svcConfig.groupSockets);
          ensureUsers = map (svc: {
            name = svc.database;
            ensureDBOwnership = true;
          }) (svcConfig.services ++ svcConfig.groupSockets);
          identMap = ''
            postgres root postgres
          ''
          + lib.concatStringsSep "\n" (
            map (svc: ''
              postgres ${mkSvcUser svc} ${svc.database}
            '') svcConfig.services
          )
          + lib.concatStringsSep "\n" (
            map (gs: ''
              postgres ${gs.database} ${gs.database}
            '') svcConfig.groupSockets
          );

          extensions = ps: [
            ps.pgvector
            ps.vectorchord
          ];
          settings = {
            shared_preload_libraries = [ "vchord.so" ];
            search_path = "\"$user\", public, vectors";
          };
        };

        systemd.services.postgresql = {
          confinement.packages = [
            pkgs.gnugrep
          ];
          path = [
            pkgs.gnugrep
          ];

          unitConfig = {
            StartLimitIntervalSec = lib.mkForce 0;
          };
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
      {
        users.users = lib.attrsets.listToAttrs (
          map (gs: {
            name = gs.database;
            value = {
              isSystemUser = true;
              group = gs.database;
            };
          }) svcConfig.groupSockets
        );
        users.groups = lib.attrsets.listToAttrs (
          map (gs: {
            name = gs.database;
            value = { };
          }) svcConfig.groupSockets
        );

        systemd.sockets = lib.attrsets.listToAttrs (
          map (gs: {
            name = "postgresql-${gs.database}";
            value = {
              wantedBy = [ "sockets.target" ];
              listenStreams = [ "${mkGroupSocketDir gs}/.s.PGSQL.5432" ];
              socketConfig = {
                SocketUser = "root";
                SocketMode = "0660";
                DirectoryMode = "0755";
                # Not SocketGroup=: systemd resolves even a numeric GID via
                # NSS, which for kanidm groups fails until the network is up,
                # and a failed socket never retries. "+GID" skips the lookup.
                ExecStartPost = "${pkgs.coreutils}/bin/chgrp ${
                  if builtins.isInt gs.group then "+${toString gs.group}" else gs.group
                } ${mkGroupSocketDir gs}/.s.PGSQL.5432";
              };
            };
          }) svcConfig.groupSockets
        );

        systemd.services = lib.attrsets.listToAttrs (
          map (gs: {
            name = "postgresql-${gs.database}";
            value = {
              requires = [ "postgresql.service" ];
              after = [ "postgresql.service" ];
              serviceConfig = {
                User = gs.database;
                Group = gs.database;
                ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${config.foxDen.services.postgresql.socketPath}";
                PrivateNetwork = true;
                PrivateTmp = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                NoNewPrivileges = true;
                RestrictAddressFamilies = [ "AF_UNIX" ];
              };
            };
          }) svcConfig.groupSockets
        );
      }
    ]
  );
}
