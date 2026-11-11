{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    packetfox = {
      enable = true;
      host = "packetfox";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "packetfox";
        displayName = "PacketFox";
      };
    };
  };

  # Agents (packetfox-agent.nix) and the AP firewall rules refer to this host
  # by name.
  foxDen.hosts.hosts = {
    packetfox = mkVlanHost 2 {
      dns = {
        fqdns = [ "pfox.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.45/16"
        "fd2c:f4cb:63be:2::b2d/64"
      ];
    };
  };
}
