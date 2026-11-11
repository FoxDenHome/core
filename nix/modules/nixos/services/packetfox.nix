{
  foxDenLib,
  pkgs,
  lib,
  config,
  packetfox,
  ...
}:
let
  services = foxDenLib.services;
  util = foxDenLib.util;

  svcConfig = config.foxDen.services.packetfox;
  port = 1447;

  host = foxDenLib.hosts.getByName config svcConfig.host;
  hostAddrs = lib.flatten (
    map (iface: map util.removeIPCidr iface.addresses) (lib.attrValues host.interfaces)
  );
  firstOr = pred: lib.findFirst pred "" hostAddrs;

  configFile = pkgs.writers.writeJSON "packetfox.json" (
    packetfox
    // {
      listen = "127.0.0.1:${toString port}";
      data_dir = "/var/lib/packetfox";
      sharkd = "${pkgs.wireshark-cli}/bin/sharkd";
      ssh_key_file = lib.optionalString config.foxDen.sops.available "/run/credentials/packetfox.service/ssh-key";
      # The routers send TZSP here, one UDP port per router and chain
      collector = {
        ipv4 = firstOr util.isIPv4;
        ipv6 = firstOr util.isIPv6;
        base_port = svcConfig.tzspBasePort;
      };
      limits = {
        inherit (svcConfig) max_packets max_sessions;
        max_duration = svcConfig.maxDuration;
      };
    }
  );
in
{
  options.foxDen.services.packetfox = {
    tzspBasePort = lib.mkOption {
      type = lib.types.port;
      default = 37008;
      description = "First UDP port the routers stream TZSP to";
    };
    maxDuration = lib.mkOption {
      type = lib.types.str;
      default = "30m";
      description = "Longest capture allowed";
    };
    max_packets = lib.mkOption {
      type = lib.types.ints.positive;
      default = 500000;
      description = "Most packets one capture may hold";
    };
    max_sessions = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Captures kept on disk; older ones are deleted";
    };
  }
  // (services.http.mkOptions {
    name = "PacketFox";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "packetfox";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-packetfox";
        # Captures hold everyone's traffic: Kanidm superadmins only
        oAuthGroup = "superadmins";
        target = ''
          proxy_pass http://127.0.0.1:${toString port};
          proxy_read_timeout 120s;
        '';
      }).config
      {
        # ROUTEROS_PASSWORD (user pfox), UNIFI_SSH_USERNAME, UNIFI_SSH_PASSWORD
        sops.secrets.packetfox = config.lib.foxDen.sops.mkIfAvailable { };
        sops.secrets.packetfox-ssh-key = config.lib.foxDen.sops.mkIfAvailable { };

        systemd.services.packetfox = {
          confinement.packages = [
            pkgs.packetfox
            pkgs.wireshark-cli
            configFile
          ];

          serviceConfig = {
            DynamicUser = true;
            StateDirectory = "packetfox";
            StateDirectoryMode = "0700";
            BindReadOnlyPaths = [
              "${configFile}:/etc/packetfox/config.json"
            ];
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.packetfox.path;
            LoadCredential = config.lib.foxDen.sops.mkIfAvailable "ssh-key:${config.sops.secrets.packetfox-ssh-key.path}";
            Type = "simple";
            ExecStart = [ "${pkgs.packetfox}/bin/pfox" ];
            # Stopping removes the routers' mirror rules first
            TimeoutStopSec = "60s";
            Restart = "always";
          };

          wantedBy = [ "multi-user.target" ];
        };

        # SSH to the UniFi APs, which are on mgmt
        foxDen.firewall.rules = map (ap: {
          table = "filter";
          chain = "forward";
          action = "accept";
          source = {
            host = svcConfig.host;
          };
          gateway = "router";
          destination = {
            host = ap.name;
            system = ap.system;
          };
          dstport = 22;
          protocol = "tcp";
          comment = "packetfox-ap-ssh";
        }) packetfox.aps;
      }
    ]
  );
}
