{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    aurbuild = {
      enable = true;
      host = "aurbuild";
    };
  };

  foxDen.hosts.hosts = {
    aurbuild = mkVlanHost 2 {
      dns = {
        fqdns = [
          "aurbuild-x86-64.foxden.network"
        ];
      };
      firewall.ingressAcceptRules = [
        {
          protocol = "tcp";
          port = 873;
        }
      ];
      addresses = [
        "10.2.11.26/16"
        "fd2c:f4cb:63be:2::b1a/64"
      ];
    };
  };
}
