{ ... }:
{
  foxDen.hosts.index = 4;
  foxDen.hosts.gateway = "redfox";
  foxDen.hosts.hostingProvider = "vultr";

  foxDen.hosts.hosts =
    let
      mkIntf = (
        intf: {
          interfaces.default = {
            driver.name = "null";
          }
          // intf;
        }
      );
    in
    {
      redfox = {
        ssh = true;
      }
      // (mkIntf {
        dns = {
          fqdns = [
            "redfox.foxden.network"
            "redfox.doridian.net"
          ];
        };
        addresses = [
          "10.99.10.1"
          "fd2c:f4cb:63be::a63:a01"
          "45.76.246.55"
          "2001:19f0:8000:1897:5400:05ff:feec:cf59"
        ];
      });
    };

  foxDen.dns.records = [
    {
      fqdn = "v4-redfox.doridian.net";
      type = "A";
      ttl = 3600;
      value = "45.76.246.55";
      horizon = "external";
    }
    {
      fqdn = "v4-redfox.doridian.net";
      type = "CNAME";
      ttl = 3600;
      value = "redfox.foxden.network.";
      horizon = "internal";
    }
  ];
}
