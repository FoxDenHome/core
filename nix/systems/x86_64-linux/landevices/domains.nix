{ ... }:
{
  config.foxDen.dns.zones = {
    "foxden.network" = {
      generateNSRecords = true;
    };
    "doridian.de" = {
      registrar = "inwx";
      generateNSRecords = true;
    };
    "doridian.net" = {
      generateNSRecords = true;
    };
    "darksignsonline.com" = { };
    "f0x.es" = {
      generateNSRecords = true;
    };
    "foxcav.es" = { };
    "wifilogin.org" = { };

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
      fqdn = "ping.wifilogin.org";
      type = "CNAME";
      value = "deyhdso7blgcp.cloudfront.net";
      horizon = "*";
    }
    {
      fqdn = "_cf10a4931031653818d260f48ba096d8.ping.wifilogin.org";
      type = "CNAME";
      value = "_fe975e472c21c1885b6ba93313e2187e.jkddzztszm.acm-validations.aws";
      horizon = "*";
    }
  ];

  config.foxDen.dns.authorities = {
    default = {
      admin = "hostmaster@doridian.net";
      nameservers = [
        "ns1.doridian.net."
        "ns2.doridian.de."
        "ns3.foxden.network."
        "ns4.f0x.es."
      ];
    };
    upstream = {
      admin = "support@cloudns.net";
      nameservers = [
        "pns41.cloudns.net."
        "pns42.cloudns.net."
        "pns43.cloudns.net."
        "pns44.cloudns.net."
      ];
    };
  };
}
