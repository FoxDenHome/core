{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    mirror = {
      enable = true;
      host = "mirror";
      tls.enable = true;
      dataDir = "/mnt/zhdd/mirror";
      archMirrorId = "archlinux.doridian.net";
      sources.archlinux = {
        rsyncUrl = "rsync://mirror.doridian.net/archlinux/";
        forceSync = true;
      };
      sources.cachyos = {
        rsyncUrl = "rsync://mirror.doridian.net/cachyos/";
        forceSync = true;
      };
      sources."foxdenaur/x86_64" = {
        rsyncUrl = "rsync://aurbuild-x86-64.foxden.network/foxdenaur/";
        forceSync = true;
      };
    };
  };

  foxDen.hosts.hosts = {
    mirror = mkVlanHost 2 {
      dns = {
        fqdns = [
          "mirror.foxden.network"
          "archlinux.foxden.network"
          "cachyos.foxden.network"
        ];
        dynDns = true;
        critical = true;
      };
      firewall.ingressAcceptRules = [
        {
          protocol = "tcp";
          port = 873;
        }
      ];
      webservice.enable = true;
      addresses = [
        "10.2.11.17/16"
        "fd2c:f4cb:63be:2::b11/64"
      ];
    };
  };
}
