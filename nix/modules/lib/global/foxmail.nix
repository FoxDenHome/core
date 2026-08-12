{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;

  mailerByGateway = {
    router = "mailer.foxden.network";
    icefox = "10.99.12.1";
  };

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
      mergeLists =
        a: b:
        let
          allEMails = lib.uniqueStrings ((lib.attrNames a) ++ (lib.attrNames b));
        in
        lib.genAttrs allEMails (email: (a.${email} or [ ]) ++ (b.${email} or [ ]));
      subnets = builtins.foldl' mergeLists { } (map renderInterface ifacesFiltered);
    in
    lib.recursiveUpdate boilerplateCfg {
      sender = {
        dkim.domains = lib.uniqueStrings (map emailDomain (lib.attrNames subnets));
      };
      receiver = {
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

  # Consumer must fill in sender.domain, receiver.smtp.domain, sender.dkim.selector
  boilerplateCfg = {
    sender = {
      require-tls = true;
      mta-sts = {
        enable = true;
        cache-size = 4096;
      };
    };
    receiver = {
      smtp = {
        listener = ":2525";
        greeting = "foxMail ESMTP";
      };
    };
    http.listener = ":9002";
  };
in
{
  inherit boilerplateCfg;

  getForGateway =
    config: gateway:
    let
      ifaces = foxDenLib.global.hosts.getInterfacesFromHosts config.foxDen.hosts.hosts;
    in
    mkForGateway gateway ifaces;

  make =
    nixosConfigurations:
    let
      ifaces = foxDenLib.global.hosts.getInterfaces nixosConfigurations;
      gateways = foxDenLib.global.hosts.getGateways nixosConfigurations;
    in
    lib.attrsets.genAttrs gateways (gateway: mkForGateway gateway ifaces);

  nixosModule =
    {
      config,
      pkgs,
      ...
    }:
    let
      mailer = mailerByGateway.${config.foxDen.hosts.gateway};
    in
    {
      lib.foxDen.mailerHost = mailer;
      security.wrappers.sendmail = {
        source = pkgs.writeShellScript "sendmail.sh" ''
          export FOXMAIL_DEFAULT_SERVER='${mailer}:2525'
          exec ${pkgs.foxMail}/bin/sendmail "$@"
        '';
        owner = "root";
        group = "root";
      };
    };
}
