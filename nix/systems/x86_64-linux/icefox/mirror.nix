{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
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
    mirror = mkV6Host {
      dns = {
        fqdns = [
          "mirror.doridian.net"
          "archlinux.doridian.net"
          "cachyos.doridian.net"
        ];
      };
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 873;
        }
      ];
      webservice.enable = true;
      addresses = [
        "2604:2dc0:500:b03::1:3/112"
        "10.99.12.3/24"
        "fd2c:f4cb:63be::a63:c03/120"
      ];
    };
  };
}
