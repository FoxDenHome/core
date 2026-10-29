{
  lib,
  pkgs,
  config,
  foxDenLib,
  hostName,
  ...
}:
let
  cfg = config.foxDen.deviceCerts;

  # Eaton cards make their own key and get a CSR signed, so only the
  # CyberPower ones get a certificate from security.acme
  acmeDevices = lib.filterAttrs (_: device: device.type == "cyberpower") cfg.devices;
in
{
  options.foxDen.deviceCerts = with lib.types; {
    enable = lib.mkEnableOption ''
      Let's Encrypt certificates for the web UIs of UPS/ATS network cards.
      DNS-01 goes through the dynamic TXT records _acme-challenge.<fqdn> at
      dns.he.net. The devicecerts-acme secret holds their DDNS keys as
      HURRICANE_TOKENS=<fqdn>:<key>,<fqdn>:<key>,... (tofu output
      he_dynamic_keys). The cards log in to oauth-jit-radius (which has to run
      on this host) as the static RADIUS user devicecerts, whose password is
      DEVICECERTS_PASSWORD=<password> in the devicecerts-radius secret
    '';
    devices = lib.mkOption {
      type = attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              type = lib.mkOption {
                type = enum [
                  "eaton"
                  "cyberpower"
                ];
              };
              fqdn = lib.mkOption {
                type = str;
                default = "${name}.foxden.network";
              };
              address = lib.mkOption {
                type = foxDenLib.types.ipv4WithoutCidr;
                description = "Address the card sends RADIUS requests from";
              };
            };
          }
        )
      );
      default = { };
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets = config.lib.foxDen.sops.mkIfAvailable {
      devicecerts-acme = { };
      devicecerts-radius = { };
    };

    foxDen.services.oauth-jit-radius = {
      staticUsers.devicecerts = {
        groups = [ "superadmins" ];
        allowedIPs = lib.mapAttrsToList (_: device: device.address) cfg.devices;
        passwordVariable = "DEVICECERTS_PASSWORD";
      };
      environmentFiles = config.lib.foxDen.sops.mkIfAvailable [
        config.sops.secrets.devicecerts-radius.path
      ];
    };

    security.acme = lib.mkIf (acmeDevices != { }) (
      config.lib.foxDen.sops.mkIfAvailable {
        acceptTerms = true;
        certs = lib.mapAttrs' (
          _: device:
          lib.nameValuePair device.fqdn {
            email = "ssl@foxden.network";
            # The cards only take RSA keys
            keyType = "rsa2048";
            dnsProvider = "hurricane";
            environmentFile = config.sops.secrets.devicecerts-acme.path;
          }
        ) acmeDevices;
      }
    );

    foxDen.dns.records = lib.mapAttrsToList (_: device: {
      fqdn = "_acme-challenge.${device.fqdn}";
      type = "TXT";
      value = "acme";
      ttl = 300; # dns.he.net's minimum
      dynDns = true;
      horizon = "external";
    }) cfg.devices;

    foxDen.firewall.rules = lib.mapAttrsToList (name: device: {
      table = "filter";
      chain = "forward";
      action = "accept";
      source = {
        host = hostName;
      };
      destination = {
        host = name;
        system = "landevices";
      };
      dstport = 443;
      protocol = "tcp";
      comment = "devicecerts-${hostName}-${name}-allow-https";
    }) cfg.devices;

    environment.persistence."/nix/persist/foxden/services".directories = [
      {
        directory = "/var/lib/devicecerts";
        mode = "u=rwx,g=,o=";
      }
    ];

    systemd.services = lib.mapAttrs' (
      name: device:
      lib.nameValuePair "devicecert-${name}" (
        lib.mkIf config.foxDen.sops.available {
          description = "Web UI certificate of ${device.fqdn}";
          after = [
            "network-online.target"
          ]
          ++ lib.optional (device.type == "cyberpower") "acme-${device.fqdn}.service";
          wants = [ "network-online.target" ];
          path = [
            pkgs.lego
            pkgs.openssl
          ];
          startAt = "*-*-* 04:00:00";
          serviceConfig = {
            Type = "oneshot";
            Restart = "no";
            UMask = "0077";
            EnvironmentFile = [
              config.sops.secrets.devicecerts-radius.path
            ]
            ++ lib.optional (device.type == "eaton") config.sops.secrets.devicecerts-acme.path;
            Environment = [ "DEVICECERTS_USERNAME=devicecerts" ];
            ExecStart = [
              "${pkgs.devicecert}/bin/devicecert ${device.type} ${device.fqdn} ${
                if device.type == "eaton" then "/var/lib/devicecerts/${name}" else "/var/lib/acme/${device.fqdn}"
              }"
            ];
          };
        }
      )
    ) cfg.devices;
  };
}
