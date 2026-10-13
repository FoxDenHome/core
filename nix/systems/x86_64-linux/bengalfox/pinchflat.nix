{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    pinchflat = {
      enable = true;
      host = "pinchflat";
      mediaDir = "/mnt/zhdd/nas/video/YouTube";
      tls.enable = true;
      oAuth = {
        enable = true;
        displayName = "Pinchflat";
        clientId = "pinchflat";
        imageFile = ../../../files/icons/pinchflat.png;
      };
    };
  };

  foxDen.hosts.hosts = {
    pinchflat = mkVlanHost 2 {
      dns = {
        fqdns = [ "pinchflat.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.44/16"
        "fd2c:f4cb:63be:2::b2c/64"
      ];
    };
  };
}
