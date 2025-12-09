{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
  mkMinHost = config.lib.foxDenSys.mkMinHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    wireguard."wg-deluge" = {
      host = "deluge"; # sunny bunny
      interface = {
        ips = [
          "10.69.150.182/32"
          "fc00:bbbb:bbbb:bb01::6:96b5/128"
        ];
        peers = [
          {
            allowedIPs = [
              "0.0.0.0/0"
              "::/0"
              "10.64.0.1/32"
            ];
            endpoint = "62.93.167.130:51820";
            persistentKeepalive = 25;
            publicKey = "m1DF8sQgOBo+vfdl1//sCvu2TnsHKdRzfsiszbBZQzs=";
          }
        ];
      };
    };
    deluge = {
      enable = true;
      host = "deluge";
      enableHttp = false;
      downloadsDir = "/mnt/ztank/local/nas/torrent";
    };
    kiwix = {
      enable = true;
      host = "kiwix";
      dataDir = "/mnt/zhdd/kiwix";
      tls.enable = true;
      oAuth = {
        enable = true;
        displayName = "Kiwix Offsite (IceFox)";
        clientId = "kiwix-icefox";
        bypassTrusted = true;
        imageFile = ../../../files/icons/kiwix.svg;
      };
    };
    nasweb = {
      host = "nas";
      enable = true;
      root = "/mnt/ztank/local/nas";
      tls.enable = true;
      oAuth = {
        enable = true;
        displayName = "NAS WebUI Offsite (IceFox)";
        clientId = "nas-icefox";
        bypassTrusted = true;
        imageFile = ../../../files/icons/nas.svg;
      };
    };
    nzbget = {
      enable = true;
      host = "nzbget";
      enableHttp = false;
      downloadsDir = "/mnt/ztank/local/nas/usenet";
    };
    jellyfin = {
      host = "jellyfin";
      enable = true;
      mediaDir = "/mnt/ztank/local/nas";
      tls.enable = true;
    };
  };

  foxDen.hosts.hosts = {
    nas = mkV6Host {
      dns = {
        fqdns = [ "nas-offsite.foxden.network" ];
      };
      webservice.enable = true;
      addresses = [
        "2607:5300:60:7065::1:5/112"
        "10.99.12.5/24"
        "fd2c:f4cb:63be::a63:c05/120"
      ];
    };
    nzbget = mkV6Host {
      dns = {
        fqdns = [ "nzbget-offsite.foxden.network" ];
      };
      addresses = [
        "2607:5300:60:7065::1:8/112"
        "10.99.12.8/24"
        "fd2c:f4cb:63be::a63:c08/120"
      ];
    };
    jellyfin = mkV6Host {
      dns = {
        fqdns = [ "jellyfin-offsite.foxden.network" ];
      };
      webservice.enable = true;
      addresses = [
        "2607:5300:60:7065::1:9/112"
        "10.99.12.9/24"
        "fd2c:f4cb:63be::a63:c09/120"
      ];
    };
    kiwix = mkV6Host {
      dns = {
        fqdns = [ "kiwix-offsite.foxden.network" ];
      };
      webservice.enable = true;
      addresses = [
        "2607:5300:60:7065::1:a/112"
        "10.99.12.10/24"
        "fd2c:f4cb:63be::a63:c0a/120"
      ];
    };
    deluge =
      let
        host = mkMinHost {
          dns = {
            fqdns = [ "deluge-offsite.foxden.network" ];
          };
          addresses = [
            "10.99.12.11/24"
            "fd2c:f4cb:63be::a63:c0b/120"
          ];
          sysctls = {
            "net.ipv6.conf.INTERFACE.accept_ra_defrtr" = "0";
          };
        };
      in
      {
        nameservers = [ "10.64.0.1" ];
        interfaces.foxden = host.interfaces.foxden;
      };
  };
}
