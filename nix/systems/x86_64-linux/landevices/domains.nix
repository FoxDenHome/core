{ ... }:
{
  config.foxDen.dns.zones = {
    "foxden.network" = {
      generateNSRecords = true;
      registrar = "porkbun";
    };
    "doridian.de" = {
      generateNSRecords = true;
      registrar = "inwx";
    };
    "doridian.net" = {
      generateNSRecords = true;
      registrar = "porkbun";
    };
    "darksignsonline.com" = {
      registrar = "porkbun";
    };
    "f0x.es" = {
      generateNSRecords = true;
      registrar = "inwx";
    };
    "foxcav.es" = {
      registrar = "inwx";
    };

    "e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa" = {
      registrar = "local";
      email = null;
    };
    "10.in-addr.arpa" = {
      registrar = "local";
      email = null;
    };
    "41.68.100.in-addr.arpa" = {
      registrar = "local";
      email = null;
    };
  };

  # The registrars delegate to the default authority. Its vanity names are
  # ALIASes (generateNSRecords) to ClouDNS, with glue records at the registrars.
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
