{ ... }:
let
  mkWanRecs = (
    suffix: v4: v6: [
      {
        fqdn = "${suffix}.foxden.network";
        type = "A";
        value = v4;
        ttl = 300;
        dynDns = true;
        horizon = "external";
      }
      {
        fqdn = "${suffix}.foxden.network";
        type = "AAAA";
        value = v6;
        ttl = 300;
        dynDns = true;
        horizon = "external";
      }
      {
        fqdn = "v4-${suffix}.foxden.network";
        type = "A";
        value = v4;
        ttl = 300;
        dynDns = true;
        horizon = "external";
      }
      {
        fqdn = "v4-${suffix}.foxden.network";
        type = "CNAME";
        value = "${suffix}.foxden.network.";
        ttl = 300;
        horizon = "internal";
      }
    ]
  );
in
{
  config.foxDen.dns.records = [
    {
      fqdn = "vpn.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "v4-wan.foxden.network.";
      horizon = "external";
    }
    {
      fqdn = "vpn.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.1.1";
      horizon = "internal";
    }
    {
      fqdn = "v4-vpn.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "v4-wan.foxden.network.";
      horizon = "external";
    }
    {
      fqdn = "v4-vpn.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.1.1";
      horizon = "internal";
    }
    {
      fqdn = "ext-router.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "router.foxden.network.";
      horizon = "external";
    }
    {
      fqdn = "ext-router-backup.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "router-backup.foxden.network.";
      horizon = "external";
    }
    {
      fqdn = "ext-router.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.6.1";
      horizon = "internal";
    }
    {
      fqdn = "ext-router-backup.foxden.network";
      type = "A";
      ttl = 3600;
      value = "10.2.6.2";
      horizon = "internal";
    }
    {
      fqdn = "ntp.foxden.network";
      type = "CNAME";
      ttl = 3600;
      value = "wan.foxden.network.";
      horizon = "external";
    }
    {
      fqdn = "hosts.foxden.network";
      type = "TXT";
      ttl = 3600;
      value = "v=spf1 a:ext-router.foxden.network a:ext-router-backup.foxden.network a:router.foxden.network a:router-backup.foxden.network -all";
      horizon = "*";
    }
  ]
  ++ (mkWanRecs "wan" "10.2.0.1" "fd2c:f4cb:63be:2::1")
  ++ (mkWanRecs "router" "10.2.1.1" "fd2c:f4cb:63be:2::101")
  ++ (mkWanRecs "router-backup" "10.2.1.2" "fd2c:f4cb:63be:2::102");
}
