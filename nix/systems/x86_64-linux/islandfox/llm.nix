{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    llama-cpp = {
      enable = true;
      host = "llm";
    };
  };

  foxDen.hosts.hosts = {
    llm = mkVlanHost 2 {
      dns = {
        fqdns = [ "llm.foxden.network" ];
      };
      firewall.ingressAcceptRules = [
        {
          source = "10.2.0.0/16";
          comment = "lan-llm";
          port = config.foxDen.services.llama-cpp.port;
          protocol = "tcp";
        }
        {
          source = "fd2c:f4cb:63be:2::/64";
          comment = "lan-llm";
          port = config.foxDen.services.llama-cpp.port;
          protocol = "tcp";
        }
      ];
      addresses = [
        "10.2.11.38/16"
        "fd2c:f4cb:63be:2::b26/64"
      ];
    };
  };
}
