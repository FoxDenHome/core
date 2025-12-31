{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    ntfy = {
      enable = true;
      tls.enable = true;
      host = "ntfy";
    };
  };

  foxDen.hosts.hosts = {
    ntfy = mkVlanHost 3 {
      dns = {
        fqdns = [ "ntfy.foxden.network" ];
      };
      addresses = [
        "10.3.10.2/16"
        "fd2c:f4cb:63be:3::a02/64"
      ];
    };
  };
}
