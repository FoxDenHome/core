{ ... }:
{
  config.foxDen.dns.zones = {
    "doridian.de" = {
      registrar = "inwx";
      generateNSRecords = true;
    };
    "doridian.net" = {
      generateNSRecords = true;
    };
    "darksignsonline.com" = { };
    "f0x.es" = {
      registrar = "inwx";
      generateNSRecords = true;
    };
    "foxcav.es" = {
      registrar = "inwx";
    };

    "e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa" = {
      registrar = "local";
    };
    "10.in-addr.arpa" = {
      registrar = "local";
    };
    "41.68.100.in-addr.arpa" = {
      registrar = "local";
    };
  };

  config.foxDen.dns.records = [
    {
      fqdn = "doridian.net";
      type = "ALIAS";
      value = "doridian-website.foxden.network.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "www.doridian.net";
      type = "CNAME";
      value = "doridian.net.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "doridian.de";
      type = "ALIAS";
      value = "doridian-website.foxden.network.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "www.doridian.de";
      type = "CNAME";
      value = "doridian.de.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "f0x.es";
      type = "ALIAS";
      value = "foxcaves.foxden.network.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "www.f0x.es";
      type = "CNAME";
      value = "f0x.es.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "foxcav.es";
      type = "ALIAS";
      value = "foxcaves.foxden.network.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "www.foxcav.es";
      type = "CNAME";
      value = "foxcav.es.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "darksignsonline.com";
      type = "ALIAS";
      value = "darksignsonline.foxden.network.";
      ttl = 3600;
      horizon = "*";
    }
    {
      fqdn = "www.darksignsonline.com";
      type = "CNAME";
      value = "darksignsonline.com.";
      ttl = 3600;
      horizon = "*";
    }
  ];

  config.foxDen.dns.authorities = {
    default = {
      admin = "hostmaster@doridian.net";
      nameservers = [
        "ns1.doridian.net."
        "ns2.doridian.de."
        "ns3.f0x.es."
      ];
    };
    upstream = {
      admin = "hostmaster@inwx.de";
      nameservers = [
        "ns.inwx.de."
        "ns2.inwx.de."
        "ns3.inwx.eu."
      ];
    };
  };
}
