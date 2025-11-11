{
  foxDenLib,
  pkgs,
  lib,
  config,
  nixpkgs-unstable,
  systemArch,
  ...
}:
let
  services = foxDenLib.services;

  mkDir = (
    dir: {
      directory = dir;
      user = config.services.prosody.user;
      group = config.services.prosody.group;
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.xmpp;

  hostCfg = foxDenLib.hosts.getByName config svcConfig.host;
  primaryInterface = lib.lists.head (lib.attrsets.attrValues hostCfg.interfaces);
  hostName = foxDenLib.global.dns.mkHost primaryInterface.dns;

  tlsRoot = "/var/lib/foxden/http-prosody/acme";
  tlsChain = "${tlsRoot}/${hostName}.crt";
  tlsKey = "${tlsRoot}/${hostName}.key";
in
{
  options.foxDen.services.xmpp = {
  }
  // (services.http.mkOptions {
    svcName = "xmpp";
    name = "Prosody XMPP";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "prosody";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-prosody";
        target = "proxy_pass http://127.0.0.1:5280;";
        dynamicUser = false;
      }).config
      {
        systemd.services.http-prosody = {
          serviceConfig = {
            User = config.services.prosody.user;
            Group = config.services.prosody.group;
          };
        };

        systemd.services.prosody = {
          serviceConfig = {
            StateDirectory = "prosody";
            BindReadOnlyPaths = [
              "${tlsRoot}:/etc/prosody/certs"
              tlsChain
              tlsKey
              "/etc/prosody/prosody.cfg.lua"
            ];
          };
        };

        services.prosody = {
          enable = true;
          admins = [
            "doridian@foxden.network"
          ];

          ssl.cert = tlsChain;
          ssl.key = tlsKey;
          virtualHosts."foxden.network" = {
            enabled = true;
            domain = "foxden.network";
            ssl.cert = tlsChain;
            ssl.key = tlsKey;
          };

          httpInterfaces = [ "127.0.0.1" ];
          httpsInterfaces = [ "127.0.0.1" ];
          httpPorts = [ 5280 ];
          httpsPorts = [ 5281 ];

          log = "{ { min = \"info\"; to = \"*syslog\"; }; }";

          muc = [
            {
              domain = "muc.xmpp.foxden.network";
            }
          ];
          httpFileShare = {
            domain = "upload.xmpp.foxden.network";
            http_host = "xmpp.foxden.network";
            size_limit = 1024 * 1024 * 1000;
            daily_quota = 10 * 1024 * 1024 * 1000;
            expires_after = 60 * 60 * 24 * 7;
            # TODO: This is a little hacky
            extraConfig = ''
              "
                          http_external_url = "https://upload.xmpp.foxden.network"
                        --'';
          };
          extraConfig = ''
            default_storage = "sql"

            sql = {
              driver = "SQLite3";
              database = "prosody.sqlite";
            }

            -- make 0.10-distributed mod_mam use sql store
            archive_store = "archive2" -- Use the same data store as prosody-modules mod_mam

            storage = {
              -- this makes mod_mam use the sql storage backend
              archive2 = "sql";
            }

            -- https://modules.prosody.im/mod_mam.html
            archive_expires_after = "1y"

            http_max_content_size = 1024 * 1024 * 1000

            trusted_proxies = { "127.0.0.1" }

            prosodyctl_service_warnings = false
          '';
          package = nixpkgs-unstable.outputs.legacyPackages.${systemArch}.prosody.override {
            withCommunityModules = [
              "cloud_notify_extensions"
              "cloud_notify_encrypted"
              "cloud_notify_priority_tag"
              "cloud_notify_filters"
              "compat_roles"
              "discoitems"
              "sasl2"
              "sasl_ssdp"
              "sasl2_bind2"
            ];
          };
        };

        environment.persistence."/nix/persist/prosody" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/prosody")
          ];
        };
      }
    ]
  );
}
