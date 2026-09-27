{ ... }:
{
  config.foxDen.dns.zones = {
    "foxden.network" = {
      registrar = "porkbun";
    };
    "doridian.de" = {
      registrar = "inwx";
    };
    "doridian.net" = {
      registrar = "porkbun";
    };
    "darksignsonline.com" = {
      registrar = "porkbun";
    };
    "f0x.es" = {
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
  config.foxDen.dns.records = [
    {
      fqdn = "foxden.network";
      type = "TXT";
      ttl = 3600;
      value = "anthropic-domain-verification-6kmvr0=LAbewwKo7TUTgHkmwEu5HSvOT";
      horizon = "*";
    }
  ];
}
