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

  dataDir = "/var/lib/cghmn-squidcache";

  squidConfig = pkgs.writeTextFile "squid.conf" ''
    # Main config
    cache_dir ${svcConfig.cacheDir}
    cache_log stdio:${dataDir}/logs/cache.log
    access_log stdio:${dataDir}/logs/access.log
    cache_store_log stdio:${dataDir}/logs/store.log
    cache_effective_user cghmn-squidcache cghmn-squidcache

    # Access control
    ## ACL
    acl localnet src 10.0.0.0/8
    acl localnet src fc00::/7
    acl localnet src 100.64.0.0/10

    acl http_ports port 80

    ${lib.concatStringsSep "\n" (map (dom: "acl allowed_domains dstdomain ${dom}") svcConfig.domains)}

    # HTTP
    http_port 80 intercept connection-auth=off
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
      cacheDir = {
        type = path;
        default = "${dataDir}/cache";
        description = "Directory to store Squid data";
      };
      domains = {
        type = uniq (listOf str);
        default = [ "debian.org" ];
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
            ExecStartPre = [ "${pkgs.coreutils}/bin/mkdir -p '${dataDir}/logs' '${svcConfig.cacheDir}'" ];

            RestrictAddressFamilies = lib.mkForce [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];

            StateDirectory = "cghmn-squid";
          };
          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
