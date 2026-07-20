{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    donetick = {
      enable = true;
      tls.enable = true;
      host = "donetick";
      oAuth = {
        enable = true;
        clientId = "donetick";
        displayName = "tasks (Donetick)";
      };
    };
  };

  foxDen.hosts.hosts = {
    donetick = mkVlanHost 2 {
      dns = {
        fqdns = [
          "tasks.foxden.network"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.10/16"
        "fd2c:f4cb:63be:2::b0a/64"
      ];
    };
  };
}
