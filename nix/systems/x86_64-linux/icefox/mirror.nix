{ config, ... }:
let
  mkHost = config.lib.foxDenSys.mkHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    mirror = {
      enable = true;
      host = "mirror";
      tls = true;
      dataDir = "/mnt/ztank/local/mirror";
      archMirrorId = "23m.com";
      sources.archlinux = {
        rsyncUrl = "rsync://mirror.23m.com/archlinux";
        httpsUrl = "https://mirror.23m.com/archlinux";
      };
      sources.cachyos = {
        rsyncUrl = "rsync://202.61.194.133:8958/cachy";
      };
      sources.foxdenaur = {
        rsyncUrl = "rsync://mirror.foxden.network/foxdenaur";
      };
    };
  };

  foxDen.hosts.hosts = {
    mirror = mkHost {
      dns = {
        name = "mirror.doridian.net";
      };
      cnames = [
        {
          name = "cachyos.doridian.net";
        }
        {
          name = "archlinux.doridian.net";
        }
      ];
      addresses = [
        "95.216.116.139/26"
        "2a01:4f9:2b:1a42::3/112"
        "10.99.12.3/24"
        "fd2c:f4cb:63be::a63:c03/120"
      ];
      mac = "00:50:56:00:C1:7A";
    };
  };
}
