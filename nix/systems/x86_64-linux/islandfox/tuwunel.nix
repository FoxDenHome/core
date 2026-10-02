{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    tuwunel = {
      enable = true;
      host = "tuwunel";
      serverName = "foxden.network";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "tuwunel";
        displayName = "Tuwunel (Matrix)";
      };
    };
  };

  foxDen.hosts.hosts = {
    tuwunel = mkVlanHost 2 {
      dns = {
        fqdns = [
          "tuwunel.foxden.network"
          "foxden.network"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.42/16"
        "fd2c:f4cb:63be:2::b2a/64"
      ];
    };
  };
}
