{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    syncthing = {
      enable = true;
      host = "syncthing";
      tls = true;
      syncthingHost = "syncthing.foxden.network";
      webdavHost = "webdav.syncthing.foxden.network";
    };
  };

  foxDen.hosts.hosts = {
    syncthing = mkVlanHost 2 {
      dns = {
        name = "syncthing";
        zone = "foxden.network";
        dynDns = true;
      };
      snirouter.enable = true;
      cnames = [
        {
          name = "webdav.syncthing";
          zone = "foxden.network";
        }
      ];
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 22000;
        }
        {
          protocol = "udp";
          port = 22000;
        }
      ];
      addresses = [
        "10.2.11.2/16"
        "fd2c:f4cb:63be:2::b02/64"
      ];
    };
  };
}
