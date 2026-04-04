{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;
  mkHost = foxDenLib.global.dns.mkHost;
  globalConfig = foxDenLib.global.config;

  protoCfgType =
    with lib.types;
    submodule {
      options = {
        host = lib.mkOption {
          type = nullOr str;
          default = null;
        };
        proxyProtocol = lib.mkOption {
          type = nullOr bool;
          default = null;
        };
        port = lib.mkOption {
          type = nullOr ints.u16;
          default = null;
        };
      };
    };

  templateType =
    with lib.types;
    submodule {
      options = {
        default = lib.mkOption {
          type = protoCfgType;
          default = { };
        };
        http = lib.mkOption {
          type = protoCfgType;
          default = { };
        };
        https = lib.mkOption {
          type = protoCfgType;
          default = { };
        };
        quic = lib.mkOption {
          type = protoCfgType;
          default = { };
        };
        gateway = lib.mkOption {
          type = str;
        };
      };
    };

  hostType =
    with lib.types;
    submodule {
      options = {
        template = lib.mkOption {
          type = str;
        };
        gateway = lib.mkOption {
          type = str;
        };
      };
    };

  mkForGateway =
    gateway:
    { templates, hosts, ... }:
    let
      filterForGateway = lib.attrsets.filterAttrs (_: val: (val.gateway == gateway));
      removeInvalidValues = lib.attrsets.mapAttrs (
        _: val: lib.attrsets.filterAttrsRecursive (name: val: val != null && name != "gateway") val
      );
    in
    boilerplateCfg
    // {
      templates = removeInvalidValues (filterForGateway templates);
      hosts = removeInvalidValues (filterForGateway hosts);
    };

  boilerplateCfg = {
    listeners = {
      http = ":80";
      https = ":443";
      quic = ":443";
      prometheus = ":9001";
    };
    defaults = {
      backends = {
        default = {
          host = "169.254.169.254";
        };
        http = {
          port = 80;
        };
        https = {
          port = 443;
        };
        quic = {
          port = 443;
        };
      };
    };
  };
in
{
  nixosModule =
    { config, ... }:
    let
      renderInterface = (
        hostName: ifaceObj:
        let
          iface = ifaceObj.value;
          template = "${hostName}-${ifaceObj.name}";

          privateIPv4 = lib.findFirst (
            ip:
            let
              ipNoCidr = util.removeIPCidr ip;
            in
            (util.isIPv4 ipNoCidr) && (util.isPrivateIP ipNoCidr)
          ) "" iface.addresses;
        in
        lib.mkIf (privateIPv4 != "" && iface.webservice.enable) {
          templates."${template}" = {
            inherit (iface) gateway;
            default = {
              host = util.removeIPCidr privateIPv4;
              proxyProtocol = iface.webservice.proxyProtocol;
            };
            http = {
              port = iface.webservice.httpPort;
            };
            https = {
              port = iface.webservice.httpsPort;
            };
            quic = {
              port = iface.webservice.quicPort;
            };
          };

          hosts = lib.attrsets.listToAttrs (
            map (record: {
              name = mkHost record;
              value = {
                inherit (iface) gateway;
                inherit template;
              };
            }) ([ iface.dns ] ++ iface.cnames)
          );
        }
      );

      renderHost =
        { name, value }:
        lib.mkMerge (map (iface: renderInterface name iface) (lib.attrsets.attrsToList value.interfaces));
    in
    {
      options.foxDen.foxIngress.templates =
        with lib.types;
        lib.mkOption {
          type = attrsOf templateType;
          default = { };
        };
      options.foxDen.foxIngress.hosts =
        with lib.types;
        lib.mkOption {
          type = attrsOf hostType;
          default = { };
        };
      config.foxDen.foxIngress = lib.mkMerge (
        map renderHost (nixpkgs.lib.attrsets.attrsToList config.foxDen.hosts.hosts)
      );
    };

  inherit boilerplateCfg;

  getForGateway = config: gateway: mkForGateway gateway config.foxDen.foxIngress;

  make =
    nixosConfigurations:
    let
      cfg = {
        templates = globalConfig.getAttrSet [ "foxDen" "foxIngress" "templates" ] nixosConfigurations;
        hosts = globalConfig.getAttrSet [ "foxDen" "foxIngress" "hosts" ] nixosConfigurations;
      };
      gateways = foxDenLib.global.hosts.getGateways nixosConfigurations;
    in
    lib.attrsets.genAttrs gateways (gateway: mkForGateway gateway cfg);
}
