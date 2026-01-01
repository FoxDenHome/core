{ foxDenLib, config, ... }:
let
  util = foxDenLib.util;
in
{
  config.foxDen.dns.records = [
    {
      fqdn = "hosts.foxden.network";
      type = "TXT";
      ttl = 3600;
      value = "v=spf1 ${map (ip: if util.isIPv6 ip then "ip6:${ip}" else "ip4:${ip}") config.lib.foxDenSys.mainIPs} -all";
      horizon = "*";
    }
  ];
}
