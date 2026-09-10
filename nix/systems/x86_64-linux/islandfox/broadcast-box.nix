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
    broadcast-box = mkVlanHost 2 {
      dns = {
        fqdns = [
          "live.foxden.network"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 3333;
        }
        {
          protocol = "udp";
          port = 3333;
        }
      ];
      addresses = [
        "10.2.11.31/16"
        "fd2c:f4cb:63be:2::b1f/64"
      ];
    };
  };
}
