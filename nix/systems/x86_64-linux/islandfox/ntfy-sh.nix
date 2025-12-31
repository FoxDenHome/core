{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    ntfy-sh = {
      enable = true;
      tls.enable = true;
      host = "ntfy-sh";
    };
  };

  foxDen.hosts.hosts = {
    ntfy-sh = mkVlanHost 3 {
      dns = {
        fqdns = [ "ntfy-sh.foxden.network" ];
        dynDns = true;
        critical = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.2/16"
        "fd2c:f4cb:63be:3::a02/64"
      ];
    };
  };
}
