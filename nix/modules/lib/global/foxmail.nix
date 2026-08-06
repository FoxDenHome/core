{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;

  mkForGateway =
    gateway: ifaces:
    let
      ifacesFiltered = lib.filter (iface: iface.gateway == gateway) ifaces;
    in
    boilerplateCfg
    // {
      gateway = gateway;
      receiver = boilerplateCfg.receiver // {
        auth = boilerplateCfg.receiver.auth // {
          subnets = lib.mergeAttrsList (map renderInterface ifacesFiltered);
        };
      };
    };

  renderInterface = (
    iface:
    let
      privateAddrs = lib.filter util.isPrivateIP (map util.removeIPCidr iface.addresses);
    in
    if (privateAddrs != [ ]) then lib.genAttrs iface.email.allowedFrom (from: privateAddrs) else { }
  );

  # Consumer must fill in sender.dkim.selector, sender.domain, sender.receiver.domain
  boilerplateCfg = {
    sender = {
      dkim = {
        ttl = "1h";
      };
    };
    receiver = {
      auth.subnets = { };
      smtp = {
        listener = ":2525";
        greeting = "foxMail ESMTP";
      };
    };
    prometheus.listener = ":9001";
  };
in
{
  inherit boilerplateCfg;

  getForGateway = config: gateway: mkForGateway gateway config.foxDen.foxMail;

  make =
    nixosConfigurations:
    let
      gateways = foxDenLib.global.hosts.getGateways nixosConfigurations;
      ifaces = foxDenLib.global.hosts.getInterfaces nixosConfigurations;
    in
    lib.attrsets.genAttrs gateways (gateway: mkForGateway gateway ifaces);
}
