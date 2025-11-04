{ ... }:
{
  config.foxDen.dns.zones = {
    "foxden.network" = {
      nameservers = "foxden.network";
      generateNSRecords = true;
    };
    "doridian.de" = {
      registrar = "inwx";
      nameservers = "doridian.de";
      generateNSRecords = true;
    };
    "dori.fyi" = {
      registrar = "inwx";
    };
    "doridian.net" = {
      generateNSRecords = true;
    };
    "darksignsonline.com" = {};
    "f0x.es" = {};
    "foxcav.es" = {};
    "spaceage.mp" = {
      registrar = "getmp";
    };

    "c.1.2.2.0.f.8.e.0.a.2.ip6.arpa" = {
      registrar = "ripe";
      fastmail = false;
      ses = false;
    };
    "0.f.4.4.d.7.e.0.a.2.ip6.arpa" = {
      registrar = "ripe";
      fastmail = false;
      ses = false;
    };

    "e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa" = {
      registrar = "local";
    };
    "10.in-addr.arpa" = {
      registrar = "local";
    };
    "41.96.100.in-addr.arpa" = {
      registrar = "local";
    };
  };

  config.foxDen.dns.authorities = {
    "doridian.de" = { admin = "hostmaster@doridian.de"; nameservers = ["ns1.doridian.de." "ns2.doridian.de." "ns3.doridian.de." "ns4.doridian.de."]; };
    "doridian.net" = { admin = "hostmaster@doridian.net"; nameservers = ["ns1.doridian.net." "ns2.doridian.net." "ns3.doridian.net." "ns4.doridian.net."]; };
    "foxden.network" = { admin = "hostmaster@foxden.network"; nameservers = ["ns1.foxden.network." "ns2.foxden.network." "ns3.foxden.network." "ns4.foxden.network."]; };
    default = { admin = "support@cloudns.net"; nameservers = ["pns41.cloudns.net" "pns42.cloudns.net" "pns43.cloudns.net" "pns44.cloudns.net"]; };
  };
}
