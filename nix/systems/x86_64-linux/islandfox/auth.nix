{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    kanidm.server = {
      enable = true;
      tls = true;
      host = "auth";
    };
    oauth-jit-radius = {
      enable = true;
      host = "radius";
      tls = true;
      oAuth = {
        enable = true;
        clientId = "radius";
        displayName = "JIT RADIUS";
        imageFile = ../../../files/icons/radius.svg;
      };
    };
  };

  foxDen.hosts.hosts = {
    auth = mkVlanHost 2 {
      dns = {
        fqdns = [ "auth.foxden.network" ];
        dynDns = true;
        critical = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.24/16"
        "fd2c:f4cb:63be:2::b18/64"
      ];
    };
    radius = mkVlanHost 1 {
      dns = {
        fqdns = [ "radius.auth.foxden.network" ];
        dynDns = true;
        critical = true;
      };
      webservice.enable = true;
      addresses = [
        "10.1.14.2/16"
        "fd2c:f4cb:63be:1::e02/64"
      ];
    };
  };
}
