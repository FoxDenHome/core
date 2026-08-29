{
  foxDenLib,
  config,
  ...
}:
let
  ifcfg = {
    addresses = [
      "10.2.10.11/16"
      "fd2c:f4cb:63be:2::a0b/64"
    ];
    routes = foxDenLib.hosts.helpers.lan.mkRoutes 2;
    nameservers = foxDenLib.hosts.helpers.lan.mkNameservers 2;
    interface = "br-default";
    bondInterface = "bond-default";
    phyIfaces = [
      "ens1np0"
      "enp2s0"
    ];
    # ens1np0 is the thunderbolt 25GbE link, enp2s0 is the onboard fallback
    phyPrimary = "ens1np0";
    phyPvid = 2;
    mtu = 9000;
    mac = config.lib.foxDen.mkHashMac "000001";
  };
in
{
  lib.foxDenSys.mkVlanHost = foxDenLib.hosts.helpers.lan.mkVlanHost ifcfg;

  foxDen.hosts.index = 2;
  foxDen.hosts.gateway = "router";
  virtualisation.libvirtd.allowedBridges = [ ifcfg.interface ];

  systemd.network.networks = {
    "30-${ifcfg.interface}" = {
      name = ifcfg.interface;
      routes = ifcfg.routes;
      address = ifcfg.addresses;
      dns = ifcfg.nameservers;

      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = true;
      };

      bridgeVLANs = [
        {
          PVID = ifcfg.phyPvid;
          EgressUntagged = ifcfg.phyPvid;
          VLAN = toString ifcfg.phyPvid;
        }
      ];

      linkConfig = {
        MTUBytes = ifcfg.mtu;
      };
    };

    "35-${ifcfg.bondInterface}" = {
      name = ifcfg.bondInterface;
      bridge = [ ifcfg.interface ];

      bridgeVLANs = [
        {
          PVID = ifcfg.phyPvid;
          EgressUntagged = ifcfg.phyPvid;
          VLAN = "1-15";
        }
        {
          VLAN = "2001";
        }
      ];

      linkConfig = {
        MTUBytes = ifcfg.mtu;
      };
    };
  }
  // builtins.listToAttrs (
    map (phyIface: {
      name = "40-${ifcfg.bondInterface}-slave-${phyIface}";
      value = {
        name = phyIface;
        bond = [ ifcfg.bondInterface ];

        networkConfig = if phyIface == ifcfg.phyPrimary then { PrimarySlave = true; } else { };

        linkConfig = {
          MTUBytes = ifcfg.mtu;
        };
      };
    }) ifcfg.phyIfaces
  );

  systemd.network.netdevs = {
    "${ifcfg.interface}" = {
      netdevConfig = {
        Name = ifcfg.interface;
        Kind = "bridge";
        MACAddress = ifcfg.mac;
      };

      bridgeConfig = {
        VLANFiltering = true;
      };
    };

    "${ifcfg.bondInterface}" = {
      netdevConfig = {
        Name = ifcfg.bondInterface;
        Kind = "bond";
      };

      bondConfig = {
        Mode = "active-backup";
        MIIMonitorSec = "100ms";
        PrimaryReselectPolicy = "always";
      };
    };
  };

  foxDen.hosts.hosts = {
    islandfox = {
      ssh = true;
      interfaces.default = {
        driver.name = "null";
        email.allowedFrom = [ "islandfox@foxden.network" ];
        dns = {
          fqdns = [ "islandfox.foxden.network" ];
        };
        inherit (ifcfg) mac addresses;
      };
    };
  };
}
