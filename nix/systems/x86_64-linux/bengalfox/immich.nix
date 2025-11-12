{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    immich = {
      enable = true;
      host = "immich";
      mediaDir = "/mnt/zssd/immich";
      tls = true;
      oAuth = {
        enable = true;
        clientId = "immich";
        displayName = "Immich";
        imageFile = ../../../files/icons/immich.svg;
      };
    };
  };

  foxDen.hosts.hosts = {
    immich = mkVlanHost 2 {
      dns = {
        name = "images.foxden.network";
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.23/16"
        "fd2c:f4cb:63be:2::b17/64"
      ];
    };
  };
}
