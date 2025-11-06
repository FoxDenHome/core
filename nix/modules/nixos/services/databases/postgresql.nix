{ foxDenLib, pkgs, lib, config, ... }:
let
  services = foxDenLib.services;

  socketPath = "/run/postgresql/.s.PGSQL.5432";

  svcConfig = config.foxDen.services.postgresql;

  serviceType = with lib.types; submodule {
    options = {
      name = lib.mkOption {
        type = str;
      };
      proxy = lib.mkEnableOption "Enable PostgreSQL proxy for 127.0.0.1 access";
      targetService = lib.mkOption {
        type = str;
      };
      user = lib.mkOption {
        type = nullOr str;
        default = null;
        description = "User to connect as (defaults to targetService)";
      };
    };
  };

  mkProxyTo = (clientSvc: if clientSvc.proxy then (lib.mkMerge [
    (services.make {
      name = "postgresql-${clientSvc.name}";
      overrideHost = config.foxDen.services.${clientSvc.name}.host;
      inherit svcConfig pkgs config;
    }).config.systemd.services
    {
      "postgresql-${clientSvc.name}" = {
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          User = clientSvc.name;
          Group = clientSvc.name;
          ExecStart = [
            "${pkgs.socat}/bin/socat TCP-LISTEN:5432,bind=127.0.0.1,reuseaddr,fork UNIX-CLIENT:${socketPath}"
          ];
        };
      };
    }
  ]) else {});
in
{
  options.foxDen.services.postgresql = with lib.types; services.mkOptions { svcName = "postgresql"; name = "PostgreSQL"; } // {
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

  config = lib.mkIf svcConfig.enable (lib.mkMerge [
    (services.make {
      name = "postgresql";
      inherit svcConfig pkgs config;
    }).config
    {
      foxDen.services.postgresql = {
        host = "postgresql";
        inherit socketPath;
      };

      foxDen.hosts.hosts = {
        postgresql.interfaces = {};
      };

      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_16;
        enableTCPIP = false;
        ensureDatabases = map (svc: svc.name) svcConfig.services;
        ensureUsers = map (svc: {
          inherit (svc) name;
          ensureDBOwnership = true;
        }) svcConfig.services;
        identMap = ''
          postgres root postgres
        '' + lib.concatStringsSep "\n" (map (svc: ''
          postgres ${if svc.user == null then svc.targetService else svc.user} ${svc.name}
        '') svcConfig.services);
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
          { directory = "/var/lib/postgresql"; user = "postgres"; group = "postgres"; mode = "u=rwx,g=rx,o="; }
        ];
      };
    }
    {
      systemd.services = lib.attrsets.listToAttrs (map (pgSvc: let
        svcName = if pgSvc.proxy then "postgresql-${pgSvc.name}" else pgSvc.targetService;
      in
      {
        name = svcName;
        value = {
          requires = [ "postgresql.service" ];
          after = [ "postgresql.service" ];
          serviceConfig = {
            BindReadOnlyPaths = [
              "/run/postgresql"
            ];
            Environment = [
              "POSTGRESQL_SOCKET=${socketPath}"
            ];
          };
        };
      }) svcConfig.services);
    }
    {
      systemd.services = lib.attrsets.listToAttrs (map (pgSvc: let
        svcName = if pgSvc.proxy then "postgresql-${pgSvc.name}" else pgSvc.targetService;
        usrName = if pgSvc.proxy then pgSvc.name else pgSvc.targetService;
      in
      {
        name = pgSvc.targetService;
        value = let
          deps = if pgSvc.proxy then ["${svcName}.service"] else [];
        in {
          requires = deps;
          after = deps;
          serviceConfig = {
            Environment = [
              "POSTGRESQL_DATABASE=${pgSvc.name}"
              "POSTGRESQL_USERNAME=${usrName}"
            ] ++ (if pgSvc.proxy then [
              "POSTGRESQL_HOST=127.0.0.1"
              "POSTGRESQL_PORT=5432"
              "POSTGRESQL_PASSWORD="
            ] else []);
          };
        };
      }) svcConfig.services);
    }
    {
      systemd.services = lib.mkMerge (map mkProxyTo svcConfig.services);
    }
  ]);
}
