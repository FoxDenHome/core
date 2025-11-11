{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  socketPath = "/run/opensearch-uds/opensearch.sock";

  svcConfig = config.foxDen.services.opensearch;

  userType =
    with lib.types;
    submodule {
      options = {
        indexPatterns = lib.mkOption {
          type = listOf str;
        };
      };
    };

  secCfg."config.yml" = (
    pkgs.writers.writeYAML "config.yml" {
      _meta = {
        type = "config";
        config_version = 2;
      };
      config = {
        dynamic = {
          http = {
            xff = {
              enabled = true;
              internalProxies = "127.0.0.1";
            };
          };
          authc = {
            proxy_auth_domain = {
              http_enabled = true;
              transport_enabled = true;
              order = 0;
              http_authenticator = {
                type = "proxy";
                challenge = false;
                config = {
                  user_header = "x-auth-user";
                  roles_header = "x-auth-roles";
                };
              };
              authentication_backend = {
                type = "noop";
              };
            };
          };
        };
      };
    }
  );

  secCfg."roles.yml" = (
    pkgs.writers.writeYAML "roles.yml" (
      {
        _meta = {
          type = "roles";
          config_version = 2;
        };
      }
      // (lib.attrsets.mapAttrs (name: user: {
        reserved = false;
        hidden = false;
        index_permissions = [
          {
            index_patterns = user.indexPatterns;
            allowed_actions = [ "*" ];
          }
        ];
        cluster_permissions = [
          "indices:data/write/bulk"
          "indices:data/read/scroll"
        ];
        tenant_permissions = [ ];
      }) svcConfig.users)
    )
  );

  secCfg."roles_mapping.yml" = (
    pkgs.writers.writeYAML "roles_mapping.yml" (
      {
        _meta = {
          type = "rolesmapping";
          config_version = 2;
        };
        all_access = {
          reserved = true;
          hidden = false;
          backend_roles = [ ];
          hosts = [ ];
          users = [ "root" ];
          and_backend_roles = [ ];
        };
      }
      // (lib.attrsets.mapAttrs (name: user: {
        reserved = false;
        hidden = false;
        backend_roles = [ ];
        hosts = [ ];
        users = [ name ];
        and_backend_roles = [ ];
      }) svcConfig.users)
    )
  );

  writeEmptyYaml = (
    name: type:
    pkgs.writers.writeYAML name {
      _meta = {
        type = type;
        config_version = 2;
      };
    }
  );

  secCfg."internal_users.yml" = writeEmptyYaml "internal_users.yml" "internalusers";
  secCfg."nodes_dn.yml" = writeEmptyYaml "nodes_dn.yml" "nodesdn";
  secCfg."action_groups.yml" = writeEmptyYaml "action_groups.yml" "actiongroups";
  secCfg."tenants.yml" = writeEmptyYaml "tenants.yml" "tenants";
  secCfg."whitelist.yml" = writeEmptyYaml "whitelist.yml" "whitelist";
in
{
  options.foxDen.services.opensearch =
    with lib.types;
    services.mkOptions {
      svcName = "opensearch";
      name = "OpenSearch";
    }
    // {
      users = lib.mkOption {
        type = attrsOf userType;
        default = { };
      };
      services = lib.mkOption {
        type = listOf str;
        default = [ ];
        description = "List of services connecting to OpenSearch";
      };
      socketPath = lib.mkOption {
        type = str;
        description = "Path to OpenSearch socket (read-only)";
      };
    };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "opensearch";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "opensearch-uds";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "opensearch-security";
        inherit svcConfig pkgs config;
      }).config
      {
        foxDen.services.opensearch = {
          host = "opensearch";
          inherit socketPath;
        };
        services.opensearch.enable = true;

        foxDen.hosts.hosts = {
          opensearch.interfaces = { };
        };

        services.opensearch.settings = {
          "plugins.security.disabled" = false;
          "plugins.security.authcz.admin_dn" = [ "CN=opensearch" ];
          "plugins.security.ssl.http.enabled" = true;
          "plugins.security.ssl.http.pemkey_filepath" = "/var/lib/opensearch/config/opensearch.key";
          "plugins.security.ssl.http.pemcert_filepath" = "/var/lib/opensearch/config/opensearch.crt";
          "plugins.security.ssl.http.pemtrustedcas_filepath" = "/var/lib/opensearch/config/opensearch.crt";
          "plugins.security.ssl.transport.enabled" = true;
          "plugins.security.ssl.transport.pemkey_filepath" = "/var/lib/opensearch/config/opensearch.key";
          "plugins.security.ssl.transport.pemcert_filepath" = "/var/lib/opensearch/config/opensearch.crt";
          "plugins.security.ssl.transport.pemtrustedcas_filepath" =
            "/var/lib/opensearch/config/opensearch.crt";
          "transport.ssl.enforce_hostname_verification" = false;
        };

        systemd.services.opensearch-uds = {
          description = "OpenSearch UDS Proxy";
          after = [ "opensearch.service" ];
          wants = [ "opensearch.service" ];

          serviceConfig = {
            DynamicUser = true;
            PrivateUsers = "identity";
            Type = "simple";
            RuntimeDirectory = "opensearch-uds";
            RuntimeDirectoryPreserve = "yes";
            ExecStart = [
              "${pkgs.uds-proxy}/bin/uds-proxy -socket ${socketPath} -socket-mode 0777 -remote-https -insecure-skip-verify -force-remote-host 127.0.0.1:9200"
            ];
          };

          wantedBy = [
            "multi-user.target"
            "opensearch.target"
          ];
        };

        systemd.targets.opensearch = {
          description = "OpenSearch Service";
        };

        systemd.services.opensearch = {
          confinement.packages = [
            pkgs.gnused
          ];

          serviceConfig = {
            ExecStartPre = [
              "${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -keyout /var/lib/opensearch/config/opensearch.key -out /var/lib/opensearch/config/opensearch.crt -sha256 -days 36500 -nodes -subj '/CN=opensearch'"
            ];

            ExecStartPost = lib.mkForce [ ];
          };

          wantedBy = [ "opensearch.target" ];
        };

        systemd.services.opensearch-security = {
          confinement.packages = [
            pkgs.which
            pkgs.coreutils
            pkgs.curl
            pkgs.bash
            pkgs.gnused
            pkgs.jdk21_headless
          ];

          path = [
            pkgs.which
            pkgs.jdk21_headless
          ];

          description = "OpenSearch Security Admin Initialization";
          after = [ "opensearch.service" ];
          requires = [ "opensearch.service" ];

          serviceConfig = {
            DynamicUser = true;
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "opensearch";
            Restart = "on-failure";
            ExecStart = [
              "${pkgs.coreutils}/bin/mkdir -p /var/lib/opensearch/config/opensearch-security"
            ]
            ++ (lib.attrsets.mapAttrsToList (
              name: file:
              "${pkgs.coreutils}/bin/cp ${file} /var/lib/opensearch/config/opensearch-security/${name}"
            ) secCfg)
            ++ (map (
              name: "${pkgs.coreutils}/bin/chmod 600 /var/lib/opensearch/config/opensearch-security/${name}"
            ) (lib.attrsets.attrNames secCfg))
            ++ [
              (pkgs.writeShellScript "opensearch-start-post-foxden" ''
                set -o errexit -o pipefail -o nounset -o errtrace
                shopt -s inherit_errexit

                while ! ${pkgs.bash}/bin/bash ${pkgs.opensearch}/plugins/opensearch-security/tools/securityadmin.sh \
                    -icl \
                    -nhnv \
                    -cacert /var/lib/opensearch/config/opensearch.crt \
                    -cert /var/lib/opensearch/config/opensearch.crt \
                    -key /var/lib/opensearch/config/opensearch.key \
                    -cd /var/lib/opensearch/config/opensearch-security; do
                  sleep 1
                done
              '')
            ];
          };
          wantedBy = [
            "multi-user.target"
            "opensearch.target"
          ];
        };
      }
      {
        systemd.services = lib.attrsets.genAttrs svcConfig.services (svc: {
          requires = [ "opensearch.target" ];
          after = [ "opensearch.target" ];
          serviceConfig = {
            BindReadOnlyPaths = [
              "/run/opensearch-uds"
            ];
            Environment = [
              "OS_UNIX_SOCKET_PATH=${socketPath}"
              "OS_URL=http://127.0.0.1:9200"
            ];
          };
        });
      }
    ]
  );
}
