{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    syncthing = {
      enable = true;
      host = "syncthing";
      tls = true;
      syncthingHost = "syncthing.doridian.net";
      webdavHost = "webdav.syncthing.doridian.net";
    };
  };

  foxDen.hosts.hosts = {
    syncthing = mkV6Host {
      dns = {
        name = "syncthing";
        zone = "doridian.net";
      };
      cnames = [
        {
          name = "webdav.syncthing";
          zone = "doridian.net";
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
      webservice.enable = true;
      addresses = [
        "2a01:4f9:2b:1a42::1:6/112"
        "10.99.12.6/24"
        "fd2c:f4cb:63be::a63:c06/120"
      ];
    };
  };
}
