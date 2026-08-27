{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.cghmn-squidcache;
  svcHostName = services.getFirstFQDN config svcConfig;

  dataDir = "/var/lib/cghmn-squidcache";
  defaultCacheDir = "${dataDir}/cache";

  squidConfig = pkgs.writers.writeText "squid.conf" ''
    # Main config
    cache_dir ${svcConfig.cache.type} ${svcConfig.cache.dir} ${toString svcConfig.cache.sizeMB} ${toString svcConfig.cache.l1} ${toString svcConfig.cache.l2}
    cache_log stdio:${dataDir}/logs/cache.log
    access_log stdio:${dataDir}/logs/access.log
    cache_store_log stdio:${dataDir}/logs/store.log
    pid_filename ${dataDir}/squid.pid
    visible_hostname ${svcHostName}

    shutdown_lifetime 5 seconds

    # Access control
    ## ACL
    acl localnet src 10.0.0.0/8
    acl localnet src fc00::/7
    acl localnet src 100.64.0.0/10

    acl http_ports port 80

    ${lib.concatStringsSep "\n" (map (dom: "acl allowed_domains dstdomain ${dom}") svcConfig.domains)}

    # HTTP
    http_port 80 accel allow-direct connection-auth=off
    reply_header_add Proxy-Ident "CGHMN Squid Cache (contact Doridian for issues/help)"

    http_access deny !http_ports
    http_access deny !allowed_domains
    http_access deny CONNECT

    http_access allow localhost manager
    http_access deny manager

    http_access deny to_localhost

    http_access allow localhost
    http_access allow localnet

    http_access deny all
  '';
in
{
  options.foxDen.services.cghmn-squidcache =
    with lib.types;
    {
      cache = {
        dir = lib.mkOption {
          type = path;
          default = defaultCacheDir;
          description = "Directory to store Squid data";
        };
        sizeMB = lib.mkOption {
          type = ints.positive;
          default = 100;
          description = "Squid cache size (in MBytes)";
        };
        l1 = lib.mkOption {
          type = ints.positive;
          default = 16;
          description = "Number of L1 directories";
        };
        l2 = lib.mkOption {
          type = ints.positive;
          default = 256;
          description = "Number of L2 directories";
        };
        type = lib.mkOption {
          type = enum [
            "ufs"
            "aufs"
            "diskd"
          ];
          default = "aufs";
          description = "Cache type";
        };
      };
      domains = lib.mkOption {
        type = uniq (listOf str);
        default = [ ".debian.org" ];
        description = "Which domains to permit proxying for";
      };
    }
    // services.mkOptions {
      name = "CGHMN pull-through cache (Debian etc)";
    };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "cghmn-squidcache";
        inherit svcConfig pkgs config;
      }).config
      {
        users.users.cghmn-squidcache = {
          isSystemUser = true;
          home = dataDir;
          group = "cghmn-squidcache";
        };
        users.groups.cghmn-squidcache = { };

        systemd.services.cghmn-squidcache = {
          serviceConfig = {
            Type = "simple";
            ExecStart = [ "${pkgs.squid}/bin/squid --foreground -YCs -f ${squidConfig}" ];
            ExecStartPre = [
              "${pkgs.coreutils}/bin/mkdir -p '${dataDir}/logs'"
              "${pkgs.squid}/bin/squid --foreground -z -f ${squidConfig}"
            ];

            User = "cghmn-squidcache";
            Group = "cghmn-squidcache";
            WorkingDirectory = "/var/lib/cghmn-squidcache";

            RestrictAddressFamilies = lib.mkForce [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];

            StateDirectory = "cghmn-squidcache";
            BindPaths = if svcConfig.cache.dir != defaultCacheDir then [ svcConfig.cache.dir ] else [ ];
          };
          wantedBy = [ "multi-user.target" ];
        };

        environment.persistence."/nix/persist/cghmn-squidcache" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/cghmn-squidcache";
              user = "cghmn-squidcache";
              group = "cghmn-squidcache";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
