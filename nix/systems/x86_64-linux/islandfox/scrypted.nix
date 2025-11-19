{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    scrypted = {
      enable = true;
      host = "scrypted";
    };
  };

  foxDen.hosts.hosts = {
    scrypted = mkVlanHost 2 {
      dns = {
        fqdns = [ "scrypted.foxden.network" ];
      };
      addresses = [
        "10.2.11.16/16"
        "fd2c:f4cb:63be:2::b10/64"
      ];
    };
  };
}
