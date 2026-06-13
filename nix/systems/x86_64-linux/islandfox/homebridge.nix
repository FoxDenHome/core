{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    homebridge = {
      enable = true;
      host = "homebridge";
    };
  };

  foxDen.hosts.hosts = {
    homebridge = mkVlanHost 2 {
      dns = {
        fqdns = [ "homebridge.foxden.network" ];
      };
      addresses = [
        "10.2.12.4/16"
        "fd2c:f4cb:63be:2::c04/64"
      ];
    };
  };
}
