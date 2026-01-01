{
  foxDenLib,
  nixpkgs,
  config,
  ...
}:
let
  util = foxDenLib.util;
  mkDirectives = ips: map (ip: if util.isIPv6 ip then "ip6:${ip}" else "ip4:${ip}") ips;
in
{
  config.foxDen.dns.records = [
    {
      fqdn = "hosts.foxden.network";
      type = "TXT";
      ttl = 3600;
      value = "v=spf1 ${nixpkgs.lib.concatStringsSep " " (mkDirectives config.lib.foxDenSys.mainIPs)} -all";
      horizon = "internal";
    }
    {
      fqdn = "hosts.foxden.network";
      type = "TXT";
      ttl = 3600;
      value = "v=spf1 ${
        nixpkgs.lib.concatStringsSep " " (
          mkDirectives (nixpkgs.lib.filter (ip: !util.isPrivateIP ip) config.lib.foxDenSys.mainIPs)
        )
      } -all";
      horizon = "external";
    }
  ];
}
