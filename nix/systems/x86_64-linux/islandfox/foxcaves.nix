{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    foxcaves = {
      enable = true;
      host = "foxcaves";
      email = "noreply@foxcav.es";
    };
  };

  foxDen.hosts.hosts = {
    foxcaves = mkVlanHost 2 {
      dns = {
        fqdns = [
          "foxcav.es"
          "www.foxcav.es"
          "f0x.es"
          "www.f0x.es"
        ];
        dynDns = true;
      };
      email.allowedFrom = [ "noreply@foxcav.es" ];
      webservice.enable = true;
      addresses = [
        "10.2.11.29/16"
        "fd2c:f4cb:63be:2::b1d/64"
      ];
    };
  };
}
