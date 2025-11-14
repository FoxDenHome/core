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
      tls = true;
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
      containerHost = "forgejo-runner-container";
    };
  };

  foxDen.hosts.hosts = {
    git = mkVlanHost 2 {
      dns = {
        name = "git.foxden.network";
        dynDns = true;
        critical = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.13/16"
        "fd2c:f4cb:63be:2::b0d/64"
      ];
    };
    forgejo-runner = mkVlanHost 6 {
      dns = {
        name = "islandfox-forgejo-runner.foxden.network";
      };
      addresses = [
        "10.6.11.1/16"
        "fd2c:f4cb:63be:6::b01/64"
      ];
    };
    forgejo-runner-container = mkVlanHost 6 {
      dns = {
        name = "islandfox-forgejo-runner-container.foxden.network";
      };
      addresses = [
        "10.6.11.2/16"
        "fd2c:f4cb:63be:6::b02/64"
      ];
    };
  };
}
