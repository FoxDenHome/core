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
        fqdns = [
          "syncthing.doridian.net"
          "webdav.syncthing.doridian.net"
        ];
      };
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
        "2604:2dc0:500:b03::1:6/112"
        "10.99.12.6/24"
        "fd2c:f4cb:63be::a63:c06/120"
      ];
    };
  };
}
