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
    wyoming = {
      enable = true;
      host = "voice";
    };
  };

  foxDen.hosts.hosts = {
    llm = mkVlanHost 2 {
      dns = {
        fqdns = [ "llm.foxden.network" ];
      };
      addresses = [
        "10.2.11.38/16"
        "fd2c:f4cb:63be:2::b26/64"
      ];
    };
    voice = mkVlanHost 2 {
      dns = {
        fqdns = [ "voice.foxden.network" ];
      };
      addresses = [
        "10.2.11.39/16"
        "fd2c:f4cb:63be:2::b27/64"
      ];
    };
  };
}
