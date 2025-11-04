{ lib, config, ... }:
let
  mkAuxRecords = name: zone: (map (ns: {
    inherit name;
    type = "NS";
    ttl = 86400;
    value = ns;
    horizon = "*";
  }) config.foxDen.dns.nameservers.${zone.nameservers}) ++ (if zone.fastmail or zone.ses then [
    {
      inherit name;
      type = "TXT";
      ttl = 3600;
      value = lib.concatStringsSep " " (
        ["v=spf1"]
        ++ (if zone.fastmail then ["include:spf.messagingengine.com"] else [])
        ++ (if zone.ses then ["include:amazonses.com"] else [])
        ++ ["mx" "~all"]
      );
      horizon = "*";
    }
    {
      name = "_dmarc.${name}";
      type = "TXT";
      ttl = 3600;
      value = "v=DMARC1;p=quarantine;pct=100";
      horizon = "*";
    }
  ] else []) ++ (if zone.fastmail then [
    {
      inherit name;
      type = "MX";
      ttl = 3600;
      value = "in1-smtp.messagingengine.com.";
      priority = 10;
      horizon = "*";
    }
    {
      inherit name;
      type = "MX";
      ttl = 3600;
      value = "in2-smtp.messagingengine.com.";
      priority = 20;
      horizon = "*";
    }
    {
      name  = "fm1._domainkey.${name}";
      type  = "CNAME";
      ttl   = 3600;
      value = "fm1.${name}.dkim.fmhosted.com";
      horizon = "*";
    }
    {
      name  = "fm2._domainkey.${name}";
      type  = "CNAME";
      ttl   = 3600;
      value = "fm2.${name}.dkim.fmhosted.com";
      horizon = "*";
    }
    {
      name  = "fm3._domainkey.${name}";
      type  = "CNAME";
      ttl   = 3600;
      value = "fm3.${name}.dkim.fmhosted.com";
      horizon = "*";
    }
  ] else []) ++ (lib.flatten (if zone.generateNSRecords then (builtins.genList (idx: [
    {
      name  = "ns${builtins.toString (idx+1)}.${name}";
      type  = "ALIAS";
      ttl   = 86400;
      value = builtins.elemAt config.foxDen.dns.nameservers.default idx;
      horizon = "external";
    }
    {
      name  = "ns${builtins.toString (idx+1)}.${name}";
      type  = "A";
      ttl   = 86400;
      value = "10.2.0.53";
      horizon = "internal";
    }
  ]) (lib.lists.length config.foxDen.dns.nameservers.default)) else []));
in
{
  config.foxDen.dns.zones = {
    "foxden.network" = {
      nameservers = "foxden.network";
      generateNSRecords = true;
    };
    "doridian.de" = {
      registrar = "inwx";
      nameservers = "doridian.de";
      generateNSRecords = true;
    };
    "dori.fyi" = {
      registrar = "inwx";
    };
    "doridian.net" = {
      generateNSRecords = true;
    };
    "darksignsonline.com" = {};
    "f0x.es" = {};
    "foxcav.es" = {};
    "spaceage.mp" = {
      registrar = "getmp";
    };

    "c.1.2.2.0.f.8.e.0.a.2.ip6.arpa" = {
      registrar = "ripe";
      fastmail = false;
      ses = false;
    };
    "0.f.4.4.d.7.e.0.a.2.ip6.arpa" = {
      registrar = "ripe";
      fastmail = false;
      ses = false;
    };

    "e.b.3.6.b.c.4.f.c.2.d.f.ip6.arpa" = {
      registrar = "local";
    };
    "10.in-addr.arpa" = {
      registrar = "local";
    };
    "41.96.100.in-addr.arpa" = {
      registrar = "local";
    };
  };

  config.foxDen.dns.records = lib.flatten (map ({ name, value }: mkAuxRecords name value) (lib.attrsets.attrsToList config.foxDen.dns.zones));

  config.foxDen.dns.nameservers = {
    "doridian.de" = ["ns1.doridian.de." "ns2.doridian.de." "ns3.doridian.de." "ns4.doridian.de."];
    "doridian.net" = ["ns1.doridian.net." "ns2.doridian.net." "ns3.doridian.net." "ns4.doridian.net."];
    "foxden.network" = ["ns1.foxden.network." "ns2.foxden.network." "ns3.foxden.network." "ns4.foxden.network."];
    default = ["pns41.cloudns.net" "pns42.cloudns.net" "pns43.cloudns.net" "pns44.cloudns.net"];
  };
}
