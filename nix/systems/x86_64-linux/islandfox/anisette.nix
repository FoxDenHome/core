{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    anisette = {
      enable = true;
      tls.enable = true;
      host = "anisette";
    };
  };

  foxDen.hosts.hosts = {
    anisette = mkVlanHost 2 {
      dns = {
        fqdns = [
          "ani.foxden.network"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.47/16"
        "fd2c:f4cb:63be:2::b2f/64"
      ];
    };
  };
}
