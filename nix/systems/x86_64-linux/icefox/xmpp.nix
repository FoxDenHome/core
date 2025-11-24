{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    xmpp = {
      enable = true;
      host = "xmpp";
      tls = true;
    };
  };

  foxDen.dns.records = [
    {
      fqdn = "_xmpp-client._tcp.foxden.network";
      type = "SRV";
      ttl = 3600;
      port = 5222;
      horizon = "*";
      priority = 5;
      weight = 0;
      value = "xmpp.foxden.network.";
    }
    {
      fqdn = "_xmpps-client._tcp.foxden.network";
      type = "SRV";
      ttl = 3600;
      port = 5223;
      horizon = "*";
      priority = 5;
      weight = 0;
      value = "xmpp.foxden.network.";
    }
    {
      fqdn = "_xmpp-server._tcp.foxden.network";
      type = "SRV";
      ttl = 3600;
      port = 5269;
      horizon = "*";
      priority = 5;
      weight = 0;
      value = "xmpp.foxden.network.";
    }
  ];

  foxDen.hosts.hosts = {
    xmpp = mkV6Host {
      dns = {
        fqdns = [
          "xmpp.foxden.network"
          "upload.xmpp.foxden.network"
          "foxden.network"
        ];
      };
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 5222;
        }
        {
          protocol = "tcp";
          port = 5223;
        }
        {
          protocol = "tcp";
          port = 5269;
        }
      ];
      webservice.enable = true;
      addresses = [
        "2604:2dc0:500:b03::1:4/112"
        "10.99.12.4/24"
        "fd2c:f4cb:63be::a63:c04/120"
      ];
    };
  };
}
