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

  mkForMailer =
    mailer: ifaces:
    let
      ifacesFiltered = lib.filter (iface: iface.mailer == mailer) ifaces;
      subnets = lib.mergeAttrsList (map renderInterface ifacesFiltered);
    in
    boilerplateCfg
    // {
      sender = boilerplateCfg.sender // {
        dkim.domains = lib.uniqueStrings (map emailDomain (lib.attrNames subnets));
      };
      receiver = boilerplateCfg.receiver // {
        auth = {
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
      require-tls = true;
    };
    receiver = {
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

  getForMailer = config: mailer: mkForMailer mailer config.foxDen.foxMail;

  make =
    nixosConfigurations:
    let
      ifaces = foxDenLib.global.hosts.getInterfaces nixosConfigurations;
      mailers = lib.lists.unique (map (iface: iface.mailer) ifaces);
    in
    lib.attrsets.genAttrs mailers (mailer: mkForMailer mailer ifaces);

  nixosModule =
    { config, ... }:
    {
      config.networking.hosts =
        lib.mkIf (config.foxDen.hosts.mailer == "router" && config.foxDen.hosts.gateway != "router")
          {
            "10.99.0.1" = [ "mailer.foxden.network" ];
          };
    };
}
