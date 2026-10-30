{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    syncthing = {
      enable = true;
      host = "syncthing";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "syncthing-icefox";
        displayName = "Syncthing (icefox)";
      };
      syncthingHost = "syncthing-offsite.foxden.network";
      webdavHost = "webdav.syncthing-offsite.foxden.network";
    };
  };

  foxDen.hosts.hosts = {
    syncthing = mkV6Host {
      dns = {
        fqdns = [
          "syncthing-offsite.foxden.network"
          "webdav.syncthing-offsite.foxden.network"
        ];
      };
      webservice.enable = true;
      addresses = [
        "2607:5300:60:7065::1:6/112"
        "10.99.12.6/24"
        "fd2c:f4cb:63be::a63:c06/120"
      ];
    };
  };
}
