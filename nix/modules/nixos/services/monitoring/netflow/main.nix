{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.netflow;
  yaml = pkgs.formats.yaml { };

  # Grafana only gets read access to the flow database, from its own addresses
  grafanaAddresses = lib.flatten (
    map (iface: map foxDenLib.util.removeIPCidr iface.addresses) (
      lib.attrValues (foxDenLib.hosts.getByName config config.foxDen.services.grafana.host).interfaces
    )
  );

  clickhouseConfigDir = pkgs.linkFarm "clickhouse-netflow-config" {
    "config.yaml" = yaml.generate "config.yaml" {
      logger = {
        level = "warning";
        console = 1;
      };
      path = "/var/lib/clickhouse/";
      tmp_path = "/var/lib/clickhouse/tmp/";
      user_files_path = "/var/lib/clickhouse/user_files/";
      format_schema_path = "/var/lib/clickhouse/format_schemas/";
      listen_host = "::";
      http_port = 8123;
      tcp_port = 9000;
      # Plenty for a homelab's flows, keep it from claiming 90% of islandfox
      max_server_memory_usage = 4 * 1024 * 1024 * 1024;
      mark_cache_size = 256 * 1024 * 1024;
      user_directories = {
        users_xml.path = "users.yaml";
        local_directory.path = "/var/lib/clickhouse/access/";
      };
    };
    "users.yaml" = yaml.generate "users.yaml" {
      profiles = {
        default = { };
        # 2 still lets Grafana set per-query settings
        readonly.readonly = 2;
      };
      quotas.default = { };
      users = {
        default = {
          password = "";
          networks.ip = [
            "::1"
            "127.0.0.1"
          ];
          profile = "default";
          quota = "default";
        };
        grafana = {
          password = "";
          networks.ip = grafanaAddresses;
          profile = "readonly";
          quota = "default";
          grants.query = [ "GRANT SELECT ON netflow.*" ];
        };
      };
    };
  };
in
{
  options.foxDen.services.netflow = services.mkOptions {
    name = "NetFlow/IPFIX/sFlow collector";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "netflow-clickhouse";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "vector";
        inherit svcConfig pkgs config;
      }).config
      {
        systemd.services.netflow-clickhouse = {
          description = "ClickHouse for flow data";
          confinement.packages = [ pkgs.clickhouse ];

          environment = {
            # Required for sd_notify
            CLICKHOUSE_WATCHDOG_ENABLE = "0";
          };

          serviceConfig = {
            Type = "notify";
            DynamicUser = true;
            StateDirectory = "clickhouse";
            ExecStart = "${pkgs.clickhouse}/bin/clickhouse-server --config-file=${clickhouseConfigDir}/config.yaml";
            TimeoutStartSec = "infinity";
            MemoryMax = "6G";
          };

          wantedBy = [ "multi-user.target" ];
        };

        # goflow2 decodes the router exports (netflow://:2055 takes NetFlow v9
        # and IPFIX, sflow://:6343 sFlow) and vector loads them into ClickHouse.
        services.vector = {
          enable = true;
          settings = {
            sources.goflow2 = {
              type = "exec";
              mode = "streaming";
              command = [
                "${pkgs.goflow2}/bin/goflow2"
                "-listen=sflow://:6343,netflow://:2055"
                "-addr=:8080"
                "-format=json"
                "-transport=file"
              ];
              streaming.respawn_on_exit = true;
              include_stderr = false;
              decoding.codec = "json";
            };

            transforms.flows = {
              type = "remap";
              inputs = [ "goflow2" ];
              source = ''
                received = to_int(.time_received_ns) ?? 0
                start = to_int(.time_flow_start_ns || received) ?? received
                end = to_int(.time_flow_end_ns || received) ?? received
                . = {
                  "time_received": to_int(received / 1000000000),
                  "flow_start": to_int(start / 1000000000),
                  "flow_end": to_int(end / 1000000000),
                  "type": .type,
                  "sampler": ip_to_ipv6(string(.sampler_address) ?? "::") ?? "::",
                  "etype": .etype,
                  "proto": .proto,
                  "src_addr": ip_to_ipv6(string(.src_addr) ?? "::") ?? "::",
                  "dst_addr": ip_to_ipv6(string(.dst_addr) ?? "::") ?? "::",
                  "src_port": .src_port || 0,
                  "dst_port": .dst_port || 0,
                  "bytes": .bytes || 0,
                  "packets": .packets || 0,
                  "in_if": .in_if || 0,
                  "out_if": .out_if || 0,
                  "tcp_flags": .tcp_flags || 0,
                  "sampling_rate": .sampling_rate || 0
                }
              '';
            };

            sinks.clickhouse = {
              type = "clickhouse";
              inputs = [ "flows" ];
              endpoint = "http://127.0.0.1:8123";
              database = "netflow";
              table = "flows";
              skip_unknown_fields = true;
              batch.timeout_secs = 5;
            };
          };
        };

        systemd.services.vector = {
          after = [ "netflow-clickhouse.service" ];
          wants = [ "netflow-clickhouse.service" ];
          # Like every foxDen service, never give up restarting (vector's module sets 10)
          unitConfig.StartLimitIntervalSec = lib.mkForce 0;

          confinement.packages = [
            pkgs.clickhouse
            pkgs.goflow2
          ];

          serviceConfig = {
            # Fails (and restarts vector) until ClickHouse accepts connections
            ExecStartPre = [
              "${pkgs.clickhouse}/bin/clickhouse-client --host=127.0.0.1 --queries-file=${./schema.sql}"
            ];
          };
        };
      }
    ]
  );
}
