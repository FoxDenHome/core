{
  foxDenLib,
  nixpkgs,
  config,
  ...
}:
let
  util = foxDenLib.util;
  mkDirectives =
    ips:
    nixpkgs.lib.concatStringsSep " " (
      map (ip: if util.isIPv6 ip then "ip6:${ip}" else "ip4:${ip}") ips
    );
  mkValue = ips: "v=spf1 ${mkDirectives ips} -all";
in
{
  config.foxDen.dns.records = [
    {
      fqdn = "hosts.foxden.network";
      type = "TXT";
      ttl = 3600;
      value = mkValue config.lib.foxDenSys.mainIPs;
      horizon = "internal";
    }
    {
      fqdn = "hosts.foxden.network";
      type = "TXT";
      ttl = 3600;
      value = mkValue (nixpkgs.lib.filter (ip: !util.isPrivateIP ip) config.lib.foxDenSys.mainIPs);
      horizon = "external";
    }
  ];
}
