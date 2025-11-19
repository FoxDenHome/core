{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services = {
    trustedProxies = [ "10.99.12.2/32" ];
    haproxy = {
      enable = true;
      host = "haproxy";
      configFromGateway = "icefox";
    };
  };

  foxDen.hosts.hosts = {
    haproxy = mkV6Host {
      dns = {
        fqdns = [ "icefox-haproxy.foxden.network" ];
      };
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 80;
        }
        {
          protocol = "tcp";
          port = 443;
        }
        {
          protocol = "udp";
          port = 443;
        }
      ];
      addresses = [
        "2a01:4f9:2b:1a42::1:2/112"
        "10.99.12.2/24"
        "fd2c:f4cb:63be::a63:c02/120"
      ];
    };
  };
}
