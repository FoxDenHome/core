{ config, foxDenLib, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
  # nas-smb is in the root netns, so its interface is one of this machine's.
  smbInterface = foxDenLib.hosts.getInterfaceName config "nas-smb";
  smbV4 = "10.2.11.16";
  smbV6 = "fd2c:f4cb:63be:2::b10";
  # Everything nas-smb can reach lives here instead of in main, so the root
  # netns never selects this interface for its own traffic. Arbitrary, just
  # not one of the reserved ids in rt_tables.
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
      # ksmbd has no equivalent to Samba's [homes] auto-share (no
      # per-user path substitution at all - confirmed unsupported
      # upstream, see
      # https://github.com/cifsd-team/ksmbd-tools/issues/327), so each
      # home directory is a static share restricted to its owner
      # instead.
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

    # Belt and braces: nas-smb's own routing table does now send replies
    # back out its interface, so strict reverse path filtering passes on
    # its own - but only while that table and its rules are intact. Check
    # this one interface loosely regardless: the source still has to be
    # routable, just not back out the interface it came in on.
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
        # Host routes on purpose. This machine's own address covers the
        # same subnet on ens1f0np0, and an on-link route for it here would
        # be a second, equal-length candidate in main for all of
        # 10.2.0.0/16 - so the root netns' own traffic would sometimes
        # leave through this VF.
        addresses = [
          "${smbV4}/32"
          "${smbV6}/128"
        ];
        # But ksmbd cannot work with no route at all: create_socket() in
        # fs/smb/server/transport_tcp.c binds its listener with
        # SO_BINDTODEVICE, and accepted connections inherit that, so every
        # reply's route lookup is pinned to oif = this interface and fails
        # outright when nothing here reaches the client. Hence a full set
        # of routes - including a default, which is what off-subnet clients
        # need - in a table only this interface's own source addresses can
        # select. The on-link routes come first: the kernel resolves each
        # Gateway against this same table (see the Table option).
        #
        # No prefsrc on any of them: the rules below are what steers traffic
        # here, and they match on source, so anything reaching this table
        # already has the right one. Asking for it explicitly would only
        # add a failure mode - the kernel rejects a prefsrc that is still
        # tentative, so the IPv6 ones lose a race with DAD on the address
        # this unit adds a few commands earlier.
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
        # ksmbd's sockets are the only thing on this machine that ever
        # sends from these addresses, so this is what scopes the table
        # above to it.
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
