{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    paperless = {
      enable = true;
      tls.enable = true;
      host = "paperless";
      oAuth = {
        enable = true;
        clientId = "paperless";
        displayName = "Paperless(-ngx)";
      };
    };
  };

  foxDen.hosts.hosts = {
    paperless = mkVlanHost 2 {
      dns = {
        fqdns = [
          "paperless.foxden.network"
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
