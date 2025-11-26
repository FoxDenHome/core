{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  globalConfig = foxDenLib.global.config;

  dnsRecordType =
    with lib.types;
    submodule {
      options = {
        fqdn = lib.mkOption {
          type = str;
        };
        type = lib.mkOption {
          type = str;
        };
        value = lib.mkOption {
          type = str;
        };
        ttl = lib.mkOption {
          type = ints.unsigned;
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
        algorithm = lib.mkOption {
          type = nullOr ints.unsigned;
          default = null;
        };
        fptype = lib.mkOption {
          type = nullOr ints.unsigned;
          default = null;
        };
        dynDns = lib.mkOption {
          type = bool;
          default = false;
        };
        critical = lib.mkOption {
          type = bool;
          default = false;
        };
        horizon = lib.mkOption {
          type = enum [
            "internal"
            "external"
            "*"
          ];
        };
      };
    };

  zoneType =
    with lib.types;
    submodule {
      options = {
        registrar = lib.mkOption {
          type = str;
          default = "aws";
        };
        authority = lib.mkOption {
          type = str;
          default = "default";
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

  authorityType =
    with lib.types;
    submodule {
      options = {
        nameservers = lib.mkOption {
          type = uniq (listOf str);
        };
        admin = lib.mkOption {
          type = str;
        };
      };
    };

  emptyRecord = {
    algorithm = null;
    critical = false;
    dynDns = false;
    fptype = null;
    port = null;
    priority = null;
    ttl = 3600;
    weight = null;
  };

  mkAuxRecords =
    fqdn: zone: authorities:
    map (record: emptyRecord // record) (mkAuxRecordsInt fqdn zone authorities);

  # These records are currently not validated or post-processed
  # so be careful changing anything here. In particular, none of the core fields have defaults.
  mkAuxRecordsInt =
    fqdn: zone: authorities:
    (map (ns: {
      inherit fqdn;
      type = "NS";
      ttl = 86400;
      value = ns;
      horizon = "*";
    }) authorities.${zone.authority}.nameservers)
    ++ (
      if zone.fastmail or zone.ses then
        [
          {
            inherit fqdn;
            type = "TXT";
            ttl = 3600;
            value = nixpkgs.lib.concatStringsSep " " (
              [ "v=spf1" ]
              ++ (if zone.fastmail then [ "include:spf.messagingengine.com" ] else [ ])
              ++ (if zone.ses then [ "include:amazonses.com" ] else [ ])
              ++ [
                "mx"
                "~all"
              ]
            );
            horizon = "*";
          }
          {
            fqdn = "_dmarc.${fqdn}";
            type = "TXT";
            ttl = 3600;
            value = "v=DMARC1;p=quarantine;pct=100";
            horizon = "*";
          }
        ]
      else
        [ ]
    )
    ++ (
      if zone.fastmail then
        [
          {
            inherit fqdn;
            type = "MX";
            ttl = 3600;
            value = "in1-smtp.messagingengine.com.";
            priority = 10;
            horizon = "*";
          }
          {
            inherit fqdn;
            type = "MX";
            ttl = 3600;
            value = "in2-smtp.messagingengine.com.";
            priority = 20;
            horizon = "*";
          }
          {
            fqdn = "fm1._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm1.${fqdn}.dkim.fmhosted.com";
            horizon = "*";
          }
          {
            fqdn = "fm2._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm2.${fqdn}.dkim.fmhosted.com";
            horizon = "*";
          }
          {
            fqdn = "fm3._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm3.${fqdn}.dkim.fmhosted.com";
            horizon = "*";
          }
        ]
      else
        [ ]
    )
    ++ (nixpkgs.lib.flatten (
      if zone.generateNSRecords then
        (builtins.genList (idx: [
          {
            fqdn = "ns${builtins.toString (idx + 1)}.${fqdn}";
            type = "ALIAS";
            ttl = 86400;
            value = builtins.elemAt authorities.upstream.nameservers idx;
            horizon = "*";
          }
        ]) (nixpkgs.lib.lists.length authorities.upstream.nameservers))
      else
        [ ]
    ));
in
{
  nixosModule =
    { config, ... }:
    {
      options.foxDen.dns.records =
        with lib.types;
        lib.mkOption {
          type = listOf dnsRecordType;
          default = [ ];
        };
      # NOTE: We do NOT support nested zones here, as that would complicate things
      # significantly. So don't add things like "sub.example.com" if "example.com" is already present.
      options.foxDen.dns.zones =
        with lib.types;
        lib.mkOption {
          type = attrsOf zoneType;
          default = { };
        };
      options.foxDen.dns.authorities =
        with lib.types;
        lib.mkOption {
          type = attrsOf authorityType;
          default = { };
        };
    };

  mkConfig = (
    nixosConfigurations:
    let
      authorities = globalConfig.getAttrSet [ "foxDen" "dns" "authorities" ] nixosConfigurations;
      zones = nixpkgs.lib.mapAttrs (
        name: zone:
        zone
        // {
          nameserverList = authorities.${zone.authority}.nameservers;
        }
      ) (globalConfig.getAttrSet [ "foxDen" "dns" "zones" ] nixosConfigurations);
      records =
        (globalConfig.getList [ "foxDen" "dns" "records" ] nixosConfigurations)
        ++ nixpkgs.lib.flatten (
          map ({ name, value }: mkAuxRecords name value authorities) (lib.attrsets.attrsToList zones)
        );
      horizons = lib.filter (h: h != "*") (
        lib.lists.uniqueStrings (map (record: record.horizon) records)
      );

      zoneNames = lib.attrsets.attrNames zones;

      zonedRecords = map (
        record:
        record
        // rec {
          zone = lib.findFirst (
            zone: (zone == record.fqdn) || (lib.strings.hasSuffix ".${zone}" record.fqdn)
          ) (throw "DNS record ${record.fqdn} does not belong to a defined zone") zoneNames;
          name = if (record.fqdn == zone) then "@" else (lib.strings.removeSuffix ".${zone}" record.fqdn);
          type = if (name == "@" && record.type == "CNAME") then "ALIAS" else record.type;
        }
      ) records;
    in
    {
      inherit zones;

      records = (
        lib.attrsets.genAttrs horizons (
          horizon:
          lib.attrsets.genAttrs zoneNames (
            zone:
            lib.filter (
              record: (record.horizon == horizon || record.horizon == "*") && record.zone == zone
            ) zonedRecords
          )
        )
      );
    }
  );
}
