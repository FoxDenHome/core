{
  config,
  lib,
  foxDenLib,
  firewall,
  ...
}:
let
  mainIPv4 = "167.114.157.101";

  ifcfg-foxden = {
    addresses = [
      "10.99.10.2/16"
      "fd2c:f4cb:63be::a63:a02/112"
    ];
    bridgeAddresses = [
      "10.99.12.1/24"
      "fd2c:f4cb:63be::a63:c01/120"
    ];
    interface = "br-foxden";
    phyIface = "wg-foxden";
    mac = config.lib.foxDen.mkHashMac "000001";
    mtu = 1280;
  };
  ifcfg = {
    addresses = [
      "${mainIPv4}/32"
      "2607:5300:60:7065::1/112"
    ];
    nameservers = [
      "213.186.33.99"
      "2001:41d0:3:163::1"
    ];
    mac = "3c:ec:ef:78:c1:66";
    mtu = 1500;
    interface = "br-default";
    phyIface = "eno1np0";
  };
  ifcfg-routed = {
    addresses = [
      "2607:5300:60:7065::1:1/112"
    ];
    interface = "br-routed";
    mtu = 1500;
    mac = config.lib.foxDen.mkHashMac "000002";
  };

  mkMinHost = (
    iface: {
      inherit (ifcfg) nameservers;
      interfaces.default = iface // {
        sysctls = {
          "net.ipv6.conf.INTERFACE.accept_ra" = "0";
        }
        // (iface.sysctls or { });
        addresses = lib.filter (ip: !(foxDenLib.util.isPrivateIP ip)) iface.addresses;
        webservice.enable = false;
        driver = {
          name = "bridge";
          bridge = {
            bridge = ifcfg.interface;
            vlan = 0;
            mtu = ifcfg.mtu;
          };
        };
        routes = [ ];
      };
      interfaces.foxden = iface // {
        sysctls = {
          "net.ipv6.conf.INTERFACE.accept_ra" = "0";
        }
        // (iface.sysctls or { });
        mac = null;
        addresses = lib.filter (foxDenLib.util.isPrivateIP) iface.addresses;
        driver = {
          name = "bridge";
          bridge = {
            bridge = ifcfg-foxden.interface;
            vlan = 0;
            mtu = ifcfg-foxden.mtu;
          };
        };
        routes = [
          {
            Destination = "10.0.0.0/8";
            Gateway = "10.99.12.1";
          }
          {
            Destination = "fd2c:f4cb:63be::/60";
            Gateway = "fd2c:f4cb:63be::a63:c01";
          }
        ];
      };
    }
  );
in
{
  lib.foxDenSys = {
    inherit mkMinHost;
    mkV6Host =
      iface:
      lib.mkMerge [
        (mkMinHost ({ mac = null; } // iface))
        {
          interfaces.default = {
            dns.auxAddresses = [ mainIPv4 ];
            routes = [
              {
                Destination = "::/0";
                Gateway = "2607:5300:60:7065::1:1";
              }
            ];
            driver.bridge = {
              bridge = lib.mkForce ifcfg-routed.interface;
              mtu = ifcfg-routed.mtu;
            };
          };
          interfaces.foxden.routes = [
            {
              Destination = "0.0.0.0/0";
              Gateway = "10.99.12.1";
            }
          ];
        }
      ];
  };

  foxDen.services.kanidm.externalIPs = map foxDenLib.util.removeIPCidr ifcfg.addresses;
  foxDen.hosts.index = 3;
  foxDen.hosts.gateway = "icefox";
  virtualisation.libvirtd.allowedBridges = [
    ifcfg.interface
    ifcfg-foxden.interface
    ifcfg-routed.interface
  ];

  # We don't firewall on servers, so only use port forward type rules
  networking.nftables.tables =
    let
      firewallRules = firewall.${config.foxDen.hosts.gateway};
      portForwardrules = lib.lists.filter (
        rule: rule.action == "dnat" && rule.chain == "port-forward" && rule.table == "nat"
      ) firewallRules;

      sharedIPRules = map (
        rule:
        "  ${rule.protocol} dport ${builtins.toString rule.dstport} dnat to ${rule.toAddresses} comment \"${rule.comment}\""
      ) portForwardrules;
    in
    {
      nat = {
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ip saddr 10.99.12.0/24 oifname "${ifcfg.interface}" snat to ${mainIPv4}
          }

          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
            ip daddr ${mainIPv4}/32 iifname "${ifcfg.interface}" jump sharedip
          }

          chain sharedip {
          ${builtins.concatStringsSep "\n" sharedIPRules}
          }
        '';
        family = "ip";
      };
    };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = "1";
    "net.ipv6.conf.all.forwarding" = "1";
    "net.ipv6.conf.default.forwarding" = "1";
  };

  systemd.network.networks."30-${ifcfg.interface}" = {
    name = ifcfg.interface;
    routes = [
      {
        Destination = "167.114.157.254/32";
      }
      {
        Destination = "0.0.0.0/0";
        Gateway = "167.114.157.254";
      }
      {
        Destination = "2607:5300:60:70ff:ff:ff:ff:ff/128";
      }
      {
        Destination = "::/0";
        Gateway = "2607:5300:60:70ff:ff:ff:ff:ff";
      }
    ];
    address = ifcfg.addresses;
    dns = ifcfg.nameservers;

    networkConfig = {
      IPv4Forwarding = true;
      IPv6Forwarding = true;
      IPv6ProxyNDP = true;
      IPv6ProxyNDPAddress = lib.naturalSort (
        lib.flatten (
          map
            (
              host:
              map foxDenLib.util.removeIPCidr (
                lib.lists.filter foxDenLib.util.isIPv6 host.interfaces.default.addresses
              )
            )
            (
              lib.lists.filter (
                host:
                (lib.attrsets.hasAttr "default" host.interfaces)
                && host.interfaces.default.driver.name == "bridge"
                && host.interfaces.default.driver.bridge.bridge == ifcfg-routed.interface
              ) (lib.attrValues config.foxDen.hosts.hosts)
            )
        )
      );

      DHCP = "no";
      IPv6AcceptRA = true;
    };

    linkConfig = {
      MTUBytes = ifcfg.mtu;
    };
  };
  boot.initrd.systemd.network.networks."30-${ifcfg.phyIface}" =
    config.systemd.network.networks."30-${ifcfg.interface}"
    // {
      name = ifcfg.phyIface;
    };

  systemd.network.netdevs."${ifcfg.interface}" = {
    netdevConfig = {
      Name = ifcfg.interface;
      Kind = "bridge";
      MACAddress = ifcfg.mac;
    };
  };

  systemd.network.netdevs."${ifcfg-routed.interface}" = {
    netdevConfig = {
      Name = ifcfg-routed.interface;
      Kind = "bridge";
      MACAddress = ifcfg-routed.mac;
    };
  };

  systemd.network.networks."40-${ifcfg.interface}-root" = {
    name = ifcfg.phyIface;
    bridge = [ ifcfg.interface ];
  };

  systemd.network.networks."30-${ifcfg-foxden.interface}" = {
    name = ifcfg-foxden.interface;
    address = ifcfg-foxden.bridgeAddresses;

    networkConfig = {
      IPv4Forwarding = true;
      IPv6Forwarding = true;

      DHCP = "no";
      IPv6AcceptRA = false;
    };

    linkConfig = {
      MTUBytes = ifcfg-foxden.mtu;
    };
  };

  systemd.network.networks."30-${ifcfg-routed.interface}" = {
    name = ifcfg-routed.interface;
    address = ifcfg-routed.addresses;

    networkConfig = {
      IPv6Forwarding = true;
      IPv6ProxyNDP = true;

      DHCP = "no";
      IPv6AcceptRA = false;
    };

    linkConfig = {
      MTUBytes = ifcfg-routed.mtu;
    };
  };

  systemd.network.netdevs."${ifcfg-foxden.interface}" = {
    netdevConfig = {
      Name = ifcfg-foxden.interface;
      Kind = "bridge";
      MACAddress = ifcfg-foxden.mac;
    };
  };

  foxDen.networking.provisionCriticalHosts = true;

  foxDen.services = {
    wireguard.${ifcfg-foxden.phyIface} = config.lib.foxDen.sops.mkIfAvailable {
      host = "";
      interface = {
        ips = ifcfg-foxden.addresses;
        listenPort = 13232;
        peers = [
          {
            allowedIPs = [
              "10.99.1.1/32"
              "fd2c:f4cb:63be::a63:101/128"
              "10.0.0.0/8"
              "fd2c:f4cb:63be::/60"
            ];
            endpoint = "v4-router.foxden.network:13232";
            persistentKeepalive = 25;
            publicKey = "nCTAIMDv50QhwjCw72FwP2u2pKGMcqxJ09DQ9wJdxH0=";
          }
          {
            allowedIPs = [
              "10.99.1.2/32"
              "fd2c:f4cb:63be::a63:102/128"
            ];
            endpoint = "v4-router-backup.foxden.network:13232";
            persistentKeepalive = 25;
            publicKey = "8zUl7b1frvuzcBrIA5lNsegzzyAOniaZ4tczSdoqcWM=";
          }
          {
            allowedIPs = [
              "10.99.10.1/32"
              "fd2c:f4cb:63be::a63:a01/128"
            ];
            endpoint = "redfox.doridian.net:13232";
            persistentKeepalive = 25;
            publicKey = "s1COjkpfpzfQ05ZLNLGQrlEhomlzwHv+APvUABzbSh8=";
          }
        ];
      };
    };
  };

  foxDen.dns.records = [
    {
      fqdn = "v4-icefox.doridian.net";
      type = "A";
      ttl = 3600;
      value = mainIPv4;
      horizon = "*";
    }
  ];

  # Due to OVH routing, we have two IPv6 subnets
  # - 2607:5300:60:7065::/112 for hosts which have public IPv4
  # - 2607:5300:60:7065::1:/112 for hosts without public IPv4 (routed out via mainIPv4)
  foxDen.hosts.hosts = {
    icefox =
      let
        mkIntf = subifcfg: {
          driver.name = "null";
          inherit (subifcfg) mac addresses;
          dns.fqdns = [
            "icefox.foxden.network"
            "icefox.doridian.net"
          ];
        };
      in
      {
        inherit (ifcfg) nameservers;
        interfaces.default = mkIntf ifcfg;
        interfaces.foxden = mkIntf ifcfg-foxden;
        interfaces.routed = {
          driver.name = "null";
          inherit (ifcfg-routed) mac addresses;
          dns.fqdns = [
            "icefox-routed.doridian.net"
          ];
        };
      };
  };
}
