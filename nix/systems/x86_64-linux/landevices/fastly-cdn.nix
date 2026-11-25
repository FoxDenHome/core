{ ... }:
let
  # Fastly's TLS CNAME (cdn/cdn.py checks it)
  target = "x.sni.global.fastly.net.";
  mkRecord = fqdn: type: {
    inherit fqdn type;
    ttl = 300;
    value = target;
    horizon = "external";
  };
in
{
  config.foxDen.dns.records = [
    (mkRecord "foxden.network" "ALIAS")
    (mkRecord "cdn.foxden.network" "CNAME")
    (mkRecord "www.foxden.network" "CNAME")
  ];
}
