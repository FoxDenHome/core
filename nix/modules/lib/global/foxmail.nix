{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;
  globalConfig = foxDenLib.global.config;

  mkForGateway =
    gateway:
    { auth, ... }:
    let
      filterForGateway = lib.attrsets.filterAttrs (_: val: (val.gateway == gateway));
      removeInvalidValues = lib.attrsets.mapAttrs (
        _: val: lib.attrsets.filterAttrsRecursive (name: val: val != null && name != "gateway") val
      );
    in
    boilerplateCfg
    // {
      auth.subnets = removeInvalidValues (filterForGateway auth.subnets);
    };

  # Consumer must fill in sender.dkim.selector, sender.domain, sender.receiver.domain
  boilerplateCfg = {
    sender = {
      dkim = {
        ttl = "1h";
      };
    };
    receiver = {
      smtp = {
        listener = ":2525";
        greeting = "foxMail ESMTP";
        auth.subnets = {};
      };
    };
    prometheus.listener = ":9001";
  };
in
{
  nixosModule =
    { config, ... }:
    let
      renderInterface = (
        machineName: hostName: hostVal: ifaceObj:
        let
          iface = ifaceObj.value;
          privateAddrs = lib.filter util.isPrivateIP (map util.removeIPCidr iface.addresses);
        in
        lib.mkIf (privateAddrs != []) {
          auth.subnets = lib.listToAttrs hostVal.email.allowedFrom (from: privateAddrs);
        }
      );

      renderHost =
        machineName:
        { name, value }:
        lib.mkMerge (
          map (iface: renderInterface machineName name value iface) (
            lib.attrsets.attrsToList value.interfaces
          )
        );
    in
    {
      options.foxDen.foxMail.auth.subnets =
        with lib.types;
        lib.mkOption {
          type = attrsOf (listOf str);
          default = { };
        };
      config.foxDen.foxMail = lib.mkMerge (
        map (renderHost config.networking.hostName) (
          nixpkgs.lib.attrsets.attrsToList config.foxDen.hosts.hosts
        )
      );
    };

  inherit boilerplateCfg;

  getForGateway = config: gateway: mkForGateway gateway config.foxDen.foxMail;

  make =
    nixosConfigurations:
    let
      cfg = {
        auth.subnets = globalConfig.getAttrSet [ "foxDen" "foxMail" "auth" "subnets" ] nixosConfigurations;
      };
      gateways = foxDenLib.global.hosts.getGateways nixosConfigurations;
    in
    lib.attrsets.genAttrs gateways (gateway: mkForGateway gateway cfg);
}
