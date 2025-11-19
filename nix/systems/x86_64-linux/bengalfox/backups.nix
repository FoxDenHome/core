{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    tapemgr.enable = true;
    gitbackup.enable = true;
    restic-server = {
      enable = true;
      host = "restic";
      dataDir = "/mnt/zhdd/restic";
      tls = true;
    };
  };

  foxDen.hosts.hosts = {
    restic = mkVlanHost 2 {
      dns = {
        fqdn = "restic.foxden.network";
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.12/16"
        "fd2c:f4cb:63be:2::b0c/64"
      ];
    };
  };
}
