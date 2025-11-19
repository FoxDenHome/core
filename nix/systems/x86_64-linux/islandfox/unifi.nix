{ config, foxDenLib, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    unifi = {
      enable = true;
      host = "unifi";
    };
  };

  foxDen.hosts.hosts = {
    unifi = mkVlanHost 1 {
      dns = {
        fqdn = "unifi.foxden.network";
      };
      firewall.ingressAcceptRules = foxDenLib.firewall.templates.trusted "unifi";
      addresses = [
        "10.1.10.1/16"
        "fd2c:f4cb:63be:1::a01/64"
      ];
    };
  };
}
