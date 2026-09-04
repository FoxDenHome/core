{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  fileSystems."/mnt/zhdd/nas/torrent" = {
    device = "/mnt/zssd/nas/torrent";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
  };

  fileSystems."/mnt/zhdd/nas/usenet" = {
    device = "/mnt/zssd/nas/usenet";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
  };

  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    wireguard."wg-deluge" = {
      host = "deluge"; # solid snake
      interface = {
        ips = [
          "10.70.175.10/32"
          "fc00:bbbb:bbbb:bb01::7:af09/128"
        ];
        peers = [
          {
            allowedIPs = [
              "0.0.0.0/0"
              "::/0"
              "10.64.0.1/32"
            ];
            endpoint = "23.234.81.127:51820";
            persistentKeepalive = 25;
            publicKey = "G6+A375GVmuFCAtvwgx3SWCWhrMvdQ+cboXQ8zp2ang=";
          }
        ];
      };
    };
    deluge = {
      enable = true;
      host = "deluge";
      downloadsDir = "/mnt/zssd/nas/torrent";
    };
    jellyfin = {
      enable = true;
      host = "jellyfin";
      mediaDir = "/mnt/zhdd/nas";
      tls.enable = true;
    };
    kiwix = {
      enable = true;
      host = "kiwix";
      dataDir = "/mnt/zhdd/kiwix";
      tls.enable = true;
      oAuth = {
        enable = true;
        displayName = "Kiwix Local (BengalFox)";
        clientId = "kiwix-bengalfox";
        bypassTrusted = true;
        imageFile = ../../../files/icons/kiwix.svg;
      };
    };
    nasweb = {
      host = "nas";
      enable = true;
      root = "/mnt/zhdd/nas";
      tls = {
        enable = true;
        preferPerformance = true;
      };
      oAuth = {
        enable = true;
        displayName = "NAS WebUI Local (BengalFox)";
        clientId = "nas-bengalfox";
        bypassTrusted = true;
        bypassNetworks = [ "100.68.41.0/24" ];
        imageFile = ../../../files/icons/nas.svg;
      };
    };
    nzbget = {
      enable = true;
      host = "nzbget";
      downloadsDir = "/mnt/zssd/nas/usenet";
    };
    ksmbd = {
      enable = true;
      host = "nas";
      # RoCE/SMB Direct only works on root-netns interfaces (see
      # extraInterfaces in ksmbd.nix), so the RDMA-capable interface has to
      # be named here rather than reached through the nas host's netns.
      extraInterfaces = [ "br-default" ];
      sharePaths = [
        "/mnt/zhdd/nas"
        "/mnt/zhdd/nashome"
      ];
      # ksmbd has no equivalent to Samba's [homes] auto-share (no
      # per-user path substitution at all - confirmed unsupported
      # upstream, see
      # https://github.com/cifsd-team/ksmbd-tools/issues/327), so each
      # home directory is a static share restricted to its owner
      # instead.
      settings = {
        wizzy = {
          "comment" = "wizzy's home directory";
          "browseable" = "no";
          "guest ok" = "no";
          "writable" = "yes";
          "create mask" = "0600";
          "directory mask" = "0700";
          "path" = "/mnt/zhdd/nashome/wizzy";
          "follow symlinks" = "no";
          "valid users" = "wizzy";
        };
        doridian = {
          "comment" = "doridian's home directory";
          "browseable" = "no";
          "guest ok" = "no";
          "writable" = "yes";
          "create mask" = "0600";
          "directory mask" = "0700";
          "path" = "/mnt/zhdd/nashome/doridian";
          "follow symlinks" = "no";
          "valid users" = "doridian";
        };
        share = {
          "comment" = "NAS share";
          "browseable" = "yes";
          "guest ok" = "yes";
          "read only" = "yes";
          "write list" = "wizzy doridian";
          "create mask" = "0664";
          "force create mode" = "0664";
          "force group" = "share";
          "directory mask" = "2775";
          "force directory mode" = "2775";
          "path" = "/mnt/zhdd/nas";
          "follow symlinks" = "no";
          "veto files" = "/.*/";
        };
      };
    };
  };

  networking.firewall.interfaces.br-default.allowedTCPPorts = [ 445 ];

  foxDen.hosts.hosts = {
    deluge =
      (mkVlanHost 2 {
        dns = {
          fqdns = [ "deluge.foxden.network" ];
        };
        addresses = [
          "10.2.11.8/16"
          "fd2c:f4cb:63be:2::b08/64"
        ];
        routes = [
          {
            Destination = "10.0.0.0/8";
            Gateway = "10.2.0.1";
          }
          {
            Destination = "fd2c:f4cb:63be::/48";
            Gateway = "fd2c:f4cb:63be:2::1";
          }
        ];
        sysctls = {
          "net.ipv6.conf.INTERFACE.accept_ra_defrtr" = "0";
        };
      })
      // {
        nameservers = [ "10.64.0.1" ];
      };
    jellyfin = mkVlanHost 2 {
      dns = {
        fqdns = [ "jellyfin.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.3/16"
        "fd2c:f4cb:63be:2::b03/64"
      ];
    };
    kiwix = mkVlanHost 2 {
      dns = {
        fqdns = [ "kiwix.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.6/16"
        "fd2c:f4cb:63be:2::b06/64"
      ];
    };
    nas = mkVlanHost 2 {
      dns = {
        fqdns = [ "nas.foxden.network" ];
        dynDns = true;
      };
      firewall.ingressAcceptRules = [
        {
          protocol = "tcp";
          source = "10.0.0.0/8";
          port = 445;
        }
      ];
      webservice.enable = true;
      addresses = [
        "10.2.11.1/16"
        "fd2c:f4cb:63be:2::b01/64"
      ];
    };
    nzbget = mkVlanHost 2 {
      dns = {
        fqdns = [ "nzbget.foxden.network" ];
      };
      addresses = [
        "10.2.11.9/16"
        "fd2c:f4cb:63be:2::b09/64"
      ];
    };
  };
}
