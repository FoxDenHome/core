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
        "2604:2dc0:500:b03::2/64"
        "10.99.12.2/24"
        "fd2c:f4cb:63be::a63:c02/120"
      ];
    };
  };
}
