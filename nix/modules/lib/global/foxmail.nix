{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;

  emailDomain =
    addr:
    let
      spl = lib.splitString "@" addr;
    in
    builtins.elemAt spl ((lib.length spl) - 1);

  mkForGateway =
    gateway: ifaces:
    let
      ifacesFiltered = lib.filter (iface: iface.gateway == gateway) ifaces;
      subnets = lib.mergeAttrsList (map renderInterface ifacesFiltered);
    in
    boilerplateCfg
    // {
      gateway = gateway;
      sender = boilerplateCfg.sender // {
        dkim = boilerplateCfg.sender.dkim // {
          domains = lib.uniqueStrings (map emailDomain (lib.attrNames subnets));
        };
      };
      receiver = boilerplateCfg.receiver // {
        auth = boilerplateCfg.receiver.auth // {
          inherit subnets;
        };
      };
    };

  renderInterface = (
    iface:
    let
      privateAddrs = map util.addHostCidr (
        lib.filter util.isPrivateIP (map util.removeIPCidr iface.addresses)
      );
    in
    lib.genAttrs iface.email.allowedFrom (from: privateAddrs)
  );

  # Consumer must fill in sender.domain, reciever.smtp.domain, sender.dkim.selector
  boilerplateCfg = {
    sender = {
      dkim = {
        ttl = "1h";
        headers = [
          "from"
        ];
      };
      headers = {
        FoxMail-Host = "unset";
      };
    };
    receiver = {
      auth.subnets = { };
      smtp = {
        listener = ":2525";
        greeting = "foxMail ESMTP";
      };
    };
    prometheus.listener = ":9002";
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
