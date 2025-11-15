{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    forgejo-runner = {
      enable = true;
      host = "forgejo-runner";
      containerHost = "forgejo-runner-container";
      capacity = 20;
    };
  };

  foxDen.hosts.hosts = {
    forgejo-runner = mkVlanHost 6 {
      dns = {
        name = "bengalfox-forgejo-runner.foxden.network";
      };
      addresses = [
        "10.6.11.3/16"
        "fd2c:f4cb:63be:6::b03/64"
      ];
    };
    forgejo-runner-container = mkVlanHost 6 {
      dns = {
        name = "bengalfox-forgejo-runner-container.foxden.network";
      };
      addresses = [
        "10.6.11.4/16"
        "fd2c:f4cb:63be:6::b04/64"
      ];
    };
  };
}
