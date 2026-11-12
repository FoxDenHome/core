{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    sheetfox = {
      enable = true;
      host = "sheetfox";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "sheetfox";
        displayName = "SheetFox";
      };
    };
  };

  foxDen.hosts.hosts = {
    sheetfox = mkVlanHost 2 {
      dns = {
        fqdns = [ "sheetfox.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.46/16"
        "fd2c:f4cb:63be:2::b2e/64"
      ];
    };
  };
}
