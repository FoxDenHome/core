{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    gitbackup.enable = true;
    restic-server = {
      enable = true;
      host = "restic";
      dataDir = "/mnt/ztank/restic";
      tls = true;
    };
  };

  foxDen.hosts.hosts = {
    restic = mkV6Host {
      dns = {
        fqdns = [ "restic.doridian.net" ];
      };
      webservice.enable = true;
      addresses = [
        "2607:5300:60:7065::7/112"
        "10.99.12.7/24"
        "fd2c:f4cb:63be::a63:c07/120"
      ];
    };
  };
}
