{ lib, ... } :
let
  vlans = [1 2 3 4 5 6 7 8 9];

  ipv4Root = "10.in-addr.arpa";
  ipv6Root = "e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa";
in
{
  config.foxDen.dns.records = lib.flatten (map (vlan: [
    {
      name = "1.0.${vlan}.${ipv4Root}";
      type = "PTR";
      ttl = 3600;
      value = "gateway.foxden.network.";
      horizon = "internal";
    }
    {
      name = "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.${vlan}.0.0.0.${ipv6Root}";
      type = "PTR";
      ttl = 3600;
      value = "gateway.foxden.network.";
      horizon = "internal";
    }
    {
      name = "53.0.${vlan}.${ipv4Root}";
      type = "PTR";
      ttl = 3600;
      value = "dns.foxden.network.";
      horizon = "internal";
    }
    {
      name = "5.3.0.0.0.0.0.0.0.0.0.0.0.0.0.0.${vlan}.0.0.0.${ipv6Root}";
      type = "PTR";
      ttl = 3600;
      value = "dns.foxden.network.";
      horizon = "internal";
    }
    {
      name = "123.0.${vlan}.${ipv4Root}";
      type = "PTR";
      ttl = 3600;
      value = "ntp.foxden.network.";
      horizon = "internal";
    }
    {
      name = "b.7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.${vlan}.0.0.0.${ipv6Root}";
      type = "PTR";
      ttl = 3600;
      value = "ntp.foxden.network.";
      horizon = "internal";
    }
    {
      name = "1.1.${vlan}.${ipv4Root}";
      type = "PTR";
      ttl = 3600;
      value = "router.foxden.network.";
      horizon = "internal";
    }
    {
      name = "1.0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.${vlan}.0.0.0.${ipv6Root}";
      type = "PTR";
      ttl = 3600;
      value = "router.foxden.network.";
      horizon = "internal";
    }
    {
      name = "2.1.${vlan}.${ipv4Root}";
      type = "PTR";
      ttl = 3600;
      value = "router-backup.foxden.network.";
      horizon = "internal";
    }
    {
      name = "2.0.1.0.0.0.0.0.0.0.0.0.0.0.0.0.${vlan}.0.0.0.${ipv6Root}";
      type = "PTR";
      ttl = 3600;
      value = "router-backup.foxden.network.";
      horizon = "internal";
    }
    {
      name = "123.1.${vlan}.${ipv4Root}";
      type = "PTR";
      ttl = 3600;
      value = "ntpi.foxden.network.";
      horizon = "internal";
    }
    {
      name = "b.7.1.0.0.0.0.0.0.0.0.0.0.0.0.0.${vlan}.0.0.0.${ipv6Root}";
      type = "PTR";
      ttl = 3600;
      value = "ntpi.foxden.network.";
      horizon = "internal";
    }
  ]) vlans);
}
