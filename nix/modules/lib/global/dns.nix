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
      vanityNameserver = lib.mkOption {
        type = str;
        default = "doridian.net";
      };
      email = lib.mkOption {
        type = bool;
        default = true;
      };
    };
  };
in
{
  defaultTtl = defaultTtl;

  nixosModule = { ... }: {
    options.foxDen.dns.records = with lib.types; lib.mkOption {
      type = listOf dnsRecordType;
      default = [];
    };
    # NOTE: We do NOT support nested zones here, as that would complicate things
    # significantly. So don't add things like "sub.example.com" if "example.com" is already present.
    options.foxDen.dns.zones = with lib.types; lib.mkOption {
      type = attrsOf zoneType;
      default = {
        "foxden.network" = {
          vanityNameserver = "foxden.network";
        };
        "doridian.de" = {
          registrar = "inwx";
          vanityNameserver = "doridian.de";
        };
        "dori.fyi" = {
          registrar = "inwx";
        };
        "doridian.net" = {};
        "darksignsonline.com" = {};
        "f0x.es" = {};
        "foxcav.es" = {};
        "spaceage.mp" = {
          registrar = "getmp";
        };

        "c.1.2.2.0.f.8.e.0.a.2.ip6.arpa" = {
          registrar = "ripe";
          email = false;
        };
        "0.f.4.4.d.7.e.0.a.2.ip6.arpa" = {
          registrar = "ripe";
          email = false;
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
    };
  };

  mkHost = record: record.name;

  mkConfig = (nixosConfigurations: let
    records = globalConfig.getList ["foxDen" "dns" "records"] nixosConfigurations;
    # TODO: Go back to uniqueStrings once next NixOS stable
    horizons = lib.filter (h: h != "*")
        (lib.lists.unique (map (record: record.horizon) records));
    zones = globalConfig.getAttrSet ["foxDen" "dns" "zones"] nixosConfigurations;

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
