{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    foxcaves = {
      enable = true;
      host = "foxcaves";
    };
  };

  foxDen.hosts.hosts = {
    foxcaves = mkVlanHost 3 {
      dns = {
        fqdn = "foxcav.es";
        dynDns = true;
      };
      cnames = [
        {
          fqdn = "f0x.es";
          type = "ALIAS";
        }
        {
          fqdn = "www.f0x.es";
        }
        {
          fqdn = "www.foxcav.es";
        }
      ];
      webservice.enable = true;
      addresses = [
        "10.3.10.1/16"
        "fd2c:f4cb:63be:3::a01/64"
      ];
    };
  };
}
