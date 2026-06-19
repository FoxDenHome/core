{ ... }:
{
  config.foxDen.dns.zones = {
    "foxden.network" = { };
    "doridian.de" = {
      registrar = "inwx";
    };
    "doridian.net" = { };
    "darksignsonline.com" = { };
    "f0x.es" = {
      registrar = "inwx";
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
}
