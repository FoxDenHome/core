{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
  svcConfig = config.foxDen.services.wyoming;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    wyoming = {
      enable = true;
      host = "voice";
    };
  };

  foxDen.hosts.hosts = {
    voice = mkVlanHost 2 {
      dns = {
        fqdns = [ "voice.foxden.network" ];
      };
      # Wyoming only binds IPv4 (asyncio sets IPV6_V6ONLY on "::")
      firewall.ingressAcceptRules =
        map
          (port: {
            source = "10.2.0.0/16";
            comment = "lan-wyoming";
            inherit port;
            protocol = "tcp";
          })
          [
            svcConfig.sttPort
            svcConfig.ttsPort
          ];
      addresses = [
        "10.2.11.39/16"
        "fd2c:f4cb:63be:2::b27/64"
      ];
    };
  };
}
