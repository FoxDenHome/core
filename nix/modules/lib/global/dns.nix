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
        };
        fastmail = lib.mkOption {
          type = bool;
          default = true;
        };
        email = lib.mkOption {
          type = enum [
            "arcticfox"
            "fastmail"
            "thundermail"
            "custom"
            null
          ];
          default = "fastmail";
        };
      };
    };

  emptyRecord = {
    algorithm = null;
    dynDns = false;
    fptype = null;
    port = null;
    priority = null;
    ttl = 3600;
    weight = null;
  };

  mkAuxRecords = fqdn: zone: map (record: emptyRecord // record) (mkAuxRecordsInt fqdn zone);

  # These records are currently not validated or post-processed
  # so be careful changing anything here. In particular, none of the core fields have defaults.
  mkAuxRecordsInt =
    fqdn: zone:
    (
      if zone.email != null then
        [
          {
            inherit fqdn;
            type = "TXT";
            ttl = 3600;
            value = nixpkgs.lib.concatStringsSep " " (
              [
                "v=spf1"
                "a:arcticfox.doridian.net"
              ]
              ++ (
                if zone.email == "fastmail" then
                  [ "include:spf.messagingengine.com" ]
                else if zone.email == "thundermail" then
                  [ "include:spf.thundermail.com" ]
                else
                  [ ]
              )
              ++ [ "-all" ]
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
      if zone.email == "fastmail" then
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
            value = "fm1.${fqdn}.dkim.fmhosted.com.";
            horizon = "*";
          }
          {
            fqdn = "fm2._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm2.${fqdn}.dkim.fmhosted.com.";
            horizon = "*";
          }
          {
            fqdn = "fm3._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm3.${fqdn}.dkim.fmhosted.com.";
            horizon = "*";
          }
        ]
      else if zone.email == "thundermail" then
        [
          {
            inherit fqdn;
            type = "MX";
            ttl = 3600;
            value = "mail.thundermail.com.";
            priority = 10;
            horizon = "*";
          }
          {
            fqdn = "tm1._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm1.${fqdn}.dkim.thunderhosted.com.";
            horizon = "*";
          }
          {
            fqdn = "tm2._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm2.${fqdn}.dkim.thunderhosted.com.";
            horizon = "*";
          }
          {
            fqdn = "tm3._domainkey.${fqdn}";
            type = "CNAME";
            ttl = 3600;
            value = "fm3.${fqdn}.dkim.thunderhosted.com.";
            horizon = "*";
          }
          {
            fqdn = "_smtp._tls.${fqdn}";
            type = "TXT";
            ttl = 3600;
            value = "v=TLSRPTv1; rua=mailto:postmaster@${fqdn}";
            horizon = "*";
          }
          {
            fqdn = "_mta-sts.${fqdn}";
            type = "TXT";
            ttl = 3600;
            value = "v=STSv1; id=18139500144460329770";
            horizon = "*";
          }
          {
            fqdn = "_jmap._tcp.${fqdn}";
            type = "SRV";
            ttl = 3600;
            priority = 0;
            weight = 1;
            port = 443;
            target = "mail.thundermail.com.";
            horizon = "*";
          }
          {
            fqdn = "_caldavs._tcp.${fqdn}";
            type = "SRV";
            ttl = 3600;
            priority = 0;
            weight = 1;
            port = 443;
            target = "mail.thundermail.com.";
            horizon = "*";
          }
          {
            fqdn = "_carddavs._tcp.${fqdn}";
            type = "SRV";
            ttl = 3600;
            priority = 0;
            weight = 1;
            port = 443;
            target = "mail.thundermail.com.";
            horizon = "*";
          }
          {
            fqdn = "_imaps._tcp.${fqdn}";
            type = "SRV";
            ttl = 3600;
            priority = 0;
            weight = 1;
            port = 993;
            target = "mail.thundermail.com.";
            horizon = "*";
          }
          {
            fqdn = "_submission._tcp.${fqdn}";
            type = "SRV";
            ttl = 3600;
            priority = 0;
            weight = 1;
            port = 587;
            target = "mail.thundermail.com.";
            horizon = "*";
          }
        ]
      else
        [ ]
    );
in
{
  nixosModule =
    { ... }:
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
    };

  mkConfig = (
    nixosConfigurations:
    let
      zones = nixpkgs.lib.mapAttrs (name: zone: zone) (
        globalConfig.getAttrSet [ "foxDen" "dns" "zones" ] nixosConfigurations
      );
      records =
        (globalConfig.getList [ "foxDen" "dns" "records" ] nixosConfigurations)
        ++ nixpkgs.lib.flatten (
          map ({ name, value }: mkAuxRecords name value) (lib.attrsets.attrsToList zones)
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
