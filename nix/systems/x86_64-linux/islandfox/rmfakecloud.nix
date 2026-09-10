{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    rmfakecloud = {
      enable = true;
      host = "rmfakecloud";
      tls.enable = true;
    };
  };

  foxDen.hosts.hosts = {
    rmfakecloud = mkVlanHost 2 {
      dns = {
        fqdns = [ "rmfakecloud.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.37/16"
        "fd2c:f4cb:63be:2::b25/64"
      ];
    };
  };
}
