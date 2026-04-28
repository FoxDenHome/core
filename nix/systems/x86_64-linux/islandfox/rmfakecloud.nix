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
    rmfakecloud = mkVlanHost 3 {
      dns = {
        fqdns = [ "rmfakecloud.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.7/16"
        "fd2c:f4cb:63be:3::a07/64"
      ];
    };
  };
}
