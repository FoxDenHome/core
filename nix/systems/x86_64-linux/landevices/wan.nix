{ ... }:
let
  mkWanRecs = (suffix: v4: v6: [
    {
      name = "${suffix}.foxden.network";
      type = "A";
      value = v4;
      ttl = 300;
      dynDns = true;
      horizon = "external";
    }
    {
      name = "${suffix}.foxden.network";
      type = "AAAA";
      value = v6;
      ttl = 300;
      dynDns = true;
      horizon = "external";
    }
    {
      name = "v4-${suffix}.foxden.network";
      type = "A";
      value = v4;
      ttl = 300;
      dynDns = true;
      horizon = "external";
    }
    {
      name = "v4-${suffix}.foxden.network";
      type = "CNAME";
      value = "${suffix}.foxden.network.";
      ttl = 300;
      horizon = "internal";
    }
  ]);
in
{
  config.foxDen.dns.records = [
    {
      name = "vpn.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "v4-wan.foxden.network.";
      horizon = "external";
    }
    {
      name = "vpn.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.1.1";
      horizon = "internal";
    }
    {
      name = "v4-vpn.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "v4-wan.foxden.network.";
      horizon = "external";
    }
    {
      name = "v4-vpn.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.1.1";
      horizon = "internal";
    }
    {
      name = "ext-router.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "router.foxden.network.";
      horizon = "external";
    }
    {
      name = "ext-router-backup.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "router-backup.foxden.network.";
      horizon = "external";
    }
    {
      name = "ext-router.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.6.1";
      horizon = "internal";
    }
    {
      name = "ext-router-backup.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.6.2";
      horizon = "internal";
    }
    {
      name = "ntp.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "wan.foxden.network.";
      horizon = "external";
    }
  ]
  ++ (mkWanRecs "wan" "10.2.0.1" "fd2c:f4cb:63be:2::1")
  ++ (mkWanRecs "router" "10.2.1.1" "fd2c:f4cb:63be:2::101")
  ++ (mkWanRecs "router-backup" "10.2.1.2" "fd2c:f4cb:63be:2::102");
}
