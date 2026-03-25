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
    unifi-os-server = {
      enable = true;
      host = "unifi-os-server";
    };
  };

  foxDen.hosts.hosts = {
    unifi = mkVlanHost 1 {
      dns = {
        fqdns = [ "unifi.foxden.network" ];
      };
      firewall.ingressAcceptRules = foxDenLib.firewall.templates.trusted "unifi";
      addresses = [
        "10.1.10.1/16"
        "fd2c:f4cb:63be:1::a01/64"
      ];
    };
    unifi-os-server = mkVlanHost 1 {
      dns = {
        fqdns = [ "unifi-os-server.foxden.network" ];
      };
      firewall.ingressAcceptRules = foxDenLib.firewall.templates.trusted "unifi";
      addresses = [
        "10.1.30.1/16"
        "fd2c:f4cb:63be:1::1e01/64"
      ];
    };
  };
}
