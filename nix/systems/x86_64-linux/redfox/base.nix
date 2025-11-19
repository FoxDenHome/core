{ ... }:
{
  foxDen.hosts.index = 4;
  foxDen.hosts.gateway = "redfox";

  foxDen.hosts.addPTR = false;
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
          fqdn = "redfox.foxden.network";
        };
        cnames = [
          {
            fqdn = "redfox.doridian.net";
          }
        ];
        addresses = [
          "10.99.10.1"
          "fd2c:f4cb:63be::a63:a01"
          "144.202.81.146"
          "2001:19f0:8001:f07:5400:4ff:feb1:d2e3"
        ];
      });
    };

  foxDen.dns.records = [
    {
      fqdn = "v4-redfox.doridian.net";
      type = "A";
      ttl = 3600;
      value = "144.202.81.146";
      horizon = "external";
    }
    {
      fqdn = "v4-redfox.doridian.net";
      type = "CNAME";
      ttl = 3600;
      value = "redfox.foxden.network.";
      horizon = "internal";
    }
    {
      fqdn = "redfox-dns.foxden.network";
      type = "A";
      ttl = 3600;
      value = "144.202.81.146";
      horizon = "external";
    }
    {
      fqdn = "redfox-dns.foxden.network";
      type = "AAAA";
      ttl = 3600;
      value = "2a0e:7d44:f069:ff00::3";
      horizon = "external";
    }
    {
      fqdn = "redfox-dns.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.99.11.3";
      horizon = "internal";
    }
    {
      fqdn = "redfox-dns.foxden.network";
      type = "AAAA";
      ttl = 3600;
      value = "fd2c:f4cb:63be::a63:b03";
      horizon = "internal";
    }
    {
      fqdn = "redfox-dns.doridian.net";
      type = "CNAME";
      ttl = 3600;
      value = "redfox-dns.foxden.network.";
      horizon = "*";
    }
  ];
}
