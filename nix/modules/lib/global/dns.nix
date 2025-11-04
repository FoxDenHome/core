{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  globalConfig = foxDenLib.global.config;

  defaultTtl = 3600;

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
        default = defaultTtl;
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
in
{
  defaultTtl = defaultTtl;

  nixosModule = { config, ... }: {
    options.foxDen.dns.records = with lib.types; lib.mkOption {
      type = listOf dnsRecordType;
      default = [];
    };
    # NOTE: We do NOT support nested zones here, as that would complicate things
    # significantly. So don't add things like "sub.example.com" if "example.com" is already present.
    options.foxDen.dns.zones = with lib.types; lib.mkOption {
      type = attrsOf zoneType;
      default = {};
    };
    options.foxDen.dns.nameservers = with lib.types; lib.mkOption {
      type = attrsOf (uniq (listOf str));
      default = {};
    };
  };

  mkHost = record: record.name;

  mkConfig = (nixosConfigurations: let
    nameservers = globalConfig.getAttrSet ["foxDen" "dns" "nameservers"] nixosConfigurations;
    zones = nixpkgs.lib.mapAttrs (name: zone: zone // {
      nameserverList = nameservers.${zone.nameservers};
    }) (globalConfig.getAttrSet ["foxDen" "dns" "zones"] nixosConfigurations);
    records = globalConfig.getList ["foxDen" "dns" "records"] nixosConfigurations;
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
