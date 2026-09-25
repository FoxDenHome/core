{
  config,
  pkgs,
  foxDenLib,
  ...
}:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
  # nas-smb is in the root netns, so its interface is one of this machine's.
  smbInterface = foxDenLib.hosts.getInterfaceName config "nas-smb";
  smbV4 = "10.2.11.16";
  smbV6 = "fd2c:f4cb:63be:2::b10";
  # Keeps nas-smb's routes out of main so the root netns never uses them.
  smbTable = 2016;
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

  environment.systemPackages = [
    pkgs.yt-dlp
  ];

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
      # RoCE/SMB Direct only works on root netns interfaces (see the
      # "interfaces" comment in ksmbd.nix), which is what nas-smb is for.
      host = "nas-smb";
      smbDirect = true;
      # Legacy, non-RDMA clients keep reaching SMB on the nas host itself.
      extraHosts = [ "nas" ];
      sharePaths = [
        "/mnt/zhdd/nas"
        "/mnt/zhdd/nashome"
      ];
      # ksmbd has no [homes] equivalent, so one share per user
      # (https://github.com/cifsd-team/ksmbd-tools/issues/327).
      settings =
        builtins.listToAttrs (
          map
            (user: {
              name = user;
              value = {
                "comment" = "${user}'s home directory";
                "browseable" = "no";
                "guest ok" = "no";
                "writable" = "yes";
                "create mask" = "0600";
                "directory mask" = "0700";
                "path" = "/mnt/zhdd/nashome/${user}";
                "follow symlinks" = "no";
                "valid users" = user;
              };
            })
            [
              "wizzy"
              "doridian"
              "homeassistant"
            ]
        )
        // {
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

  networking.firewall = {
    # SMB traffic for nas-smb hits this machine's own firewall rather than
    # only the router's forward chain.
    interfaces.${smbInterface}.allowedTCPPorts = [ 445 ];

    # Loose rpfilter on nas-smb, in case its routing table goes missing.
    extraReversePathFilterRules = ''
      iifname "${smbInterface}" fib saddr . mark oif exists accept
    '';
  };

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
        {
          protocol = "tcp";
          source = "fd2c:f4cb:63be::/60";
          port = 445;
        }
      ];
      webservice.enable = true;
      addresses = [
        "10.2.11.1/16"
        "fd2c:f4cb:63be:2::b01/64"
      ];
    };
    nas-smb =
      (mkVlanHost 2 {
        dns = {
          fqdns = [ "nas-smb.foxden.network" ];
        };
        firewall.ingressAcceptRules = [
          {
            protocol = "tcp";
            source = "10.0.0.0/8";
            port = 445;
          }
          {
            protocol = "tcp";
            source = "fd2c:f4cb:63be::/60";
            port = 445;
          }
        ];
        # Host routes, so main doesn't get a second 10.2.0.0/16 route
        # competing with ens1f0np0.
        addresses = [
          "${smbV4}/32"
          "${smbV6}/128"
        ];
        # ksmbd binds with SO_BINDTODEVICE, so replies need routes via this
        # interface. They live in smbTable, selected by source address.
        # On-link routes come first so the gateways resolve. No prefsrc: it
        # would race IPv6 DAD, and the rules already match on source.
        routes = [
          {
            Destination = "10.2.0.0/16";
            Table = smbTable;
          }
          {
            Gateway = "10.2.0.1";
            Table = smbTable;
          }
          {
            Destination = "fd2c:f4cb:63be:2::/64";
            Table = smbTable;
          }
          {
            Gateway = "fd2c:f4cb:63be:2::1";
            Table = smbTable;
          }
        ];
        routingPolicyRules = [
          {
            From = "${smbV4}/32";
            Table = smbTable;
          }
          {
            From = "${smbV6}/128";
            Table = smbTable;
          }
        ];
        sysctls = {
          "net.ipv6.conf.INTERFACE.accept_ra" = "0";
        };
      })
      // {
        netns = false;
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
