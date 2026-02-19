{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    gitbackup.enable = true;
    forgejo = {
      enable = true;
      host = "git";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "git";
        displayName = "Forgejo (git)";
        imageFile = ../../../files/icons/forgejo.svg;
      };
    };
    forgejo-runner = {
      enable = true;
      host = "forgejo-runner";
      capacity = 4;
      labels = [ "ubuntu-24.04-zen4" ];
      containerHost = "forgejo-runner-container";
    };
  };

  foxDen.hosts.hosts = {
    git = mkVlanHost 2 {
      dns = {
        fqdns = [ "git.foxden.network" ];
        dynDns = true;
        critical = true;
      };
      webservice.enable = true;
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 22;
        }
      ];
      addresses = [
        "10.2.11.13/16"
        "fd2c:f4cb:63be:2::b0d/64"
      ];
    };
    forgejo-runner = mkVlanHost 6 {
      dns = {
        fqdns = [ "islandfox-forgejo-runner.foxden.network" ];
      };
      addresses = [
        "10.6.11.1/16"
        "fd2c:f4cb:63be:6::b01/64"
      ];
    };
    forgejo-runner-container = mkVlanHost 6 {
      dns = {
        fqdns = [ "islandfox-forgejo-runner-container.foxden.network" ];
      };
      addresses = [
        "10.6.11.2/16"
        "fd2c:f4cb:63be:6::b02/64"
      ];
    };
  };
}
