{ nixpkgs, foxDenLib, flakeInputs, ... }:
let
  lib = nixpkgs.lib;
  globalConfig = foxDenLib.global.config;

  # This is 10 digits long, the exact length we need!
  dnsSerial = builtins.toString flakeInputs.self.lastModified;

  dnsRecordType = with lib.types; submodule {
    options = {
      name = lib.mkOption {
        type = str;
      };
      type = lib.mkOption {
        type = str;
      };
      value = lib.mkOption {
        type = str;
      };
      ttl = lib.mkOption {
        type = ints.positive;
        default = 3600;
      };
      priority = lib.mkOption {
        type = nullOr ints.unsigned;
        default = null;
      };
      port = lib.mkOption {
        type = nullOr ints.u16;
        default = null;
      };
      weight = lib.mkOption {
        type = nullOr ints.unsigned;
        default = null;
      };
      dynDns = lib.mkOption {
        type = bool;
        default = false;
      };
      horizon = lib.mkOption {
        type = enum [ "internal" "external" "*" ];
      };
    };
  };

  zoneType = with lib.types; submodule {
    options = {
      registrar = lib.mkOption {
        type = str;
        default = "aws";
      };
      nameservers = lib.mkOption {
        type = str;
        default = "doridian.net";
      };
      generateNSRecords = lib.mkOption {
        type = bool;
        default = false;
      };
      fastmail = lib.mkOption {
        type = bool;
        default = true;
      };
      ses = lib.mkOption {
        type = bool;
        default = true;
      };
    };
  };

  authorityType = with lib.types; submodule {
    options = {
      nameservers = lib.mkOption {
        type = uniq (listOf str);
      };
      admin = lib.mkOption {
        type = str;
      };
    };
  };

  mkAuxRecords = name: zone: authorities: (map (ns: {
    inherit name;
    type = "NS";
    ttl = 86400;
    value = ns;
    horizon = "*";
  }) authorities.${zone.nameservers}.nameservers) ++ (if zone.fastmail or zone.ses then [
    {
      inherit name;
      type = "TXT";
      ttl = 3600;
      value = nixpkgs.lib.concatStringsSep " " (
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
  ] else []) ++ (nixpkgs.lib.flatten (if zone.generateNSRecords then (builtins.genList (idx: [
    {
      name  = "ns${builtins.toString (idx+1)}.${name}";
      type  = "ALIAS";
      ttl   = 86400;
      value = builtins.elemAt authorities.default.nameservers idx;
      horizon = "external";
    }
    {
      name  = "ns${builtins.toString (idx+1)}.${name}";
      type  = "A";
      ttl   = 86400;
      value = "10.2.0.53";
      horizon = "internal";
    }
  ]) (nixpkgs.lib.lists.length authorities.default.nameservers)) else [])) ++ (
    [
      {
        inherit name;
        ttl = 86400;
        type = "SOA";
        value = "${builtins.elemAt authorities.${zone.nameservers}.nameservers 0} ${lib.replaceString "@" "." authorities.${zone.nameservers}.admin}. ${dnsSerial} 7200 1800 1209600 3600";
        horizon = "*";
      }
    ]
  );
in
{
  nixosModule = { config, ... }: {
    options.foxDen.dns.records = with lib.types; lib.mkOption {
      type = listOf dnsRecordType;
      default = [ ];
    };
    # NOTE: We do NOT support nested zones here, as that would complicate things
    # significantly. So don't add things like "sub.example.com" if "example.com" is already present.
    options.foxDen.dns.zones = with lib.types; lib.mkOption {
      type = attrsOf zoneType;
      default = { };
    };
    options.foxDen.dns.authorities = with lib.types; lib.mkOption {
      type = attrsOf authorityType;
      default = { };
    };
  };

  mkHost = record: record.name;

  mkConfig = (nixosConfigurations: let
    authorities = globalConfig.getAttrSet ["foxDen" "dns" "authorities"] nixosConfigurations;
    zones = nixpkgs.lib.mapAttrs (name: zone: zone // {
      nameserverList = authorities.${zone.nameservers}.nameservers;
    }) (globalConfig.getAttrSet ["foxDen" "dns" "zones"] nixosConfigurations);
    records = (globalConfig.getList ["foxDen" "dns" "records"] nixosConfigurations) ++ nixpkgs.lib.flatten (
      map ({ name, value }: mkAuxRecords name value authorities) (lib.attrsets.attrsToList zones)
    );
    # TODO: Go back to uniqueStrings once next NixOS stable
    horizons = lib.filter (h: h != "*")
        (lib.lists.unique (map (record: record.horizon) records));

    zoneNames = lib.attrsets.attrNames zones;

    zonedRecords = map (record: record // rec {
      zone = lib.findFirst (zone: (zone == record.name) || (lib.strings.hasSuffix ".${zone}" record.name)) "" zoneNames;
      name = if (record.name == zone) then "@" else (lib.strings.removeSuffix ".${zone}" record.name);
    }) records;
  in
  {
    inherit zones;

    records = (lib.attrsets.genAttrs horizons (horizon:
      lib.attrsets.genAttrs zoneNames (zone:
        lib.filter (record:
          (record.horizon == horizon || record.horizon == "*") && record.zone == zone)
          zonedRecords
      )
    ));
  });
}
