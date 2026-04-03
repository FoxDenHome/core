{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    immich = {
      enable = true;
      host = "immich";
      tls.enable = false;
      oAuth = {
        enable = true;
        clientId = "immich-demo";
        displayName = "Immich-demo";
        imageFile = ../../../files/icons/immich.svg;
      };
    };
  };

  foxDen.hosts.hosts = {
    immich = mkVlanHost 2 {
      dns = {
        fqdns = [ "images-demo.foxden.network" ];
      };
      addresses = [
        "10.2.11.223/16"
        "fd2c:f4cb:63be:2::ff17/64"
      ];
    };
  };
}
