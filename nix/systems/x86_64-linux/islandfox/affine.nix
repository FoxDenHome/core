{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    affine = {
      enable = true;
      tls.enable = true;
      host = "affine";
    };
  };

  foxDen.hosts.hosts = {
    affine = mkVlanHost 2 {
      dns = {
        fqdns = [
          "docs.foxden.network"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.7/16"
        "fd2c:f4cb:63be:2::b07/64"
      ];
    };
  };
}
