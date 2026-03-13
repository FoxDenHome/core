{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    broadcast-box = {
      enable = true;
      tls.enable = true;
      host = "broadcast-box";
    };
  };

  foxDen.hosts.hosts = {
    broadcast-box = mkVlanHost 3 {
      dns = {
        fqdns = [
          "watch.f0x.es"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.3/16"
        "fd2c:f4cb:63be:3::a03/64"
      ];
    };
  };
}
