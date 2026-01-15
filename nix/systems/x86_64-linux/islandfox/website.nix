{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    doridian-website = {
      enable = true;
      host = "doridian-website";
      tls = {
        enable = true;
        hsts = "preload";
      };
    };
    circuitjs = {
      enable = true;
      host = "circuitjs";
      tls.enable = true;
    };
  };

  foxDen.hosts.hosts = {
    doridian-website = mkVlanHost 2 {
      dns = {
        fqdns = [
          "doridian.net"
          "www.doridian.net"
          "doridian.de"
          "www.doridian.de"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.15/16"
        "fd2c:f4cb:63be:2::b0f/64"
      ];
    };
    circuitjs = mkVlanHost 2 {
      dns = {
        fqdns = [
          "circuitjs.foxden.network"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.25/16"
        "fd2c:f4cb:63be:2::b19/64"
      ];
    };
  };
}
