{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    aurbuild = {
      enable = true;
      host = "mirror";
    };
    mirror = {
      enable = true;
      host = "mirror";
      tls = true;
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
    };
  };

  foxDen.hosts.hosts = {
    mirror = mkVlanHost 2 {
      dns = {
        name = "mirror.foxden.network";
        dynDns = true;
        critical = true;
      };
      cnames = [
        {
          name = "archlinux.foxden.network";
        }
        {
          name = "cachyos.foxden.network";
        }
      ];
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
