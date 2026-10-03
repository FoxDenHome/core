{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    tuwunel = {
      enable = true;
      host = "matrix";
      serverName = "foxden.network";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "matrix";
        displayName = "Matrix (Tuwunel)";
      };
    };
  };

  foxDen.hosts.hosts = {
    matrix = mkVlanHost 2 {
      dns = {
        fqdns = [
          "matrix.foxden.network"
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
