{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.vpn-edge;

  # Tunnels get names directly below the host's first FQDN.
  domain = services.getFirstFQDN config svcConfig;
  host = foxDenLib.hosts.getByName config svcConfig.host;
  ifaceName = lib.head (lib.attrNames host.interfaces);
  certDir = "/var/lib/acme/${domain}";

  configFile = pkgs.writers.writeJSON "config.json" {
    inherit domain;
    listen = {
      http = ":80";
      https = ":443";
      # foxIngress sends PROXY v2 to the webservice proxy ports
      http_proxy = ":81";
      https_proxy = ":444";
      # QUIC (UDP); not forwarded, so only reached from inside
      control = ":${toString svcConfig.controlPort}";
    };
    trusted_proxies = config.foxDen.services.trustedProxies;
    cert = "${certDir}/fullchain.pem";
    key = "${certDir}/key.pem";
    portal_url = svcConfig.portalUrl;
    tcp_ports = {
      inherit (svcConfig.tcpPorts) first last;
    };
  };
in
{
  options.foxDen.services.vpn-edge = {
    tcpPorts = {
      first = lib.mkOption {
        type = lib.types.port;
        default = 30000;
      };
      last = lib.mkOption {
        type = lib.types.port;
        default = 30199;
      };
      range = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${toString svcConfig.tcpPorts.first}-${toString svcConfig.tcpPorts.last}";
        description = "The TCP range as a port forward takes it";
      };
    };
    controlPort = lib.mkOption {
      type = lib.types.port;
      default = 4443;
      description = "Control service UDP port (QUIC); not forwarded, devices reach it through the VPN";
    };
    provision = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        addresses = map foxDenLib.util.removeIPCidr host.interfaces.${ifaceName}.addresses;
        port = svcConfig.controlPort;
        server_name = domain;
      };
      description = "Where devices find the control service, for their provisioning";
    };
    portalUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://portal.foxden.network";
      description = "VPN portal that vouches for devices";
    };
  }
  // (services.mkOptions {
    name = "VPN expose edge";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "foxden-vpn-edge";
        inherit svcConfig pkgs config;
      }).config
      {
        # Wildcard certificates need DNS-01. _acme-challenge.<domain> is a
        # dynamic TXT record at dns.he.net; this secret holds its DDNS key as
        # HURRICANE_TOKENS=<domain>:<key> (tofu output he_dynamic_keys).
        sops.secrets.foxden-vpn-edge-acme = config.lib.foxDen.sops.mkIfAvailable { };
        security.acme = config.lib.foxDen.sops.mkIfAvailable {
          acceptTerms = true;
          certs.${domain} = {
            email = "ssl@foxden.network";
            extraDomainNames = [ "*.${domain}" ];
            dnsProvider = "hurricane";
            environmentFile = config.sops.secrets.foxden-vpn-edge-acme.path;
          };
        };
        environment.persistence."/nix/persist/foxden/services".directories =
          config.lib.foxDen.sops.mkIfAvailable
            [
              {
                directory = "/var/lib/acme";
                user = "acme";
                group = "acme";
                mode = "u=rwx,g=rx,o=rx";
              }
            ];

        foxDen.dns.records = [
          # Terraform cannot create wildcards at HE; this one is made by hand.
          {
            fqdn = "*.${domain}";
            type = "CNAME";
            value = "${domain}.";
            horizon = "external";
          }
          {
            fqdn = "_acme-challenge.${domain}";
            type = "TXT";
            value = "acme";
            ttl = 300; # dns.he.net's minimum
            dynDns = true;
            horizon = "external";
          }
        ];

        # Ports 80/443 direct and 81/444 with PROXY v2, like nginx elsewhere.
        foxDen.hosts.hosts.${svcConfig.host}.webservice.enable = true;

        # The host's FQDN gets a foxIngress template from webservice.enable;
        # every name below it goes there too.
        foxDen.foxIngress.hosts."_.${domain}" = {
          inherit (host.interfaces.${ifaceName}) gateway;
          template = "${config.networking.hostName}-${svcConfig.host}-${ifaceName}";
        };

        systemd.services.foxden-vpn-edge = {
          confinement.packages = [
            pkgs.foxden-vpn
          ];

          serviceConfig = {
            DynamicUser = true;
            # The edge reloads the certificate when it is renewed.
            SupplementaryGroups = lib.optional config.foxDen.sops.available "acme";
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
            BindReadOnlyPaths = [
              "${configFile}:/etc/foxden-vpn-edge/config.json"
              "-${certDir}"
            ];
            Type = "simple";
            ExecStart = [ "${pkgs.foxden-vpn}/bin/foxden-vpn-edge" ];
            Restart = "always";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
