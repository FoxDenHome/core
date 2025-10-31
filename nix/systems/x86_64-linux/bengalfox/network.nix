{ foxDenLib, ... }:
let
  ifcfg = {
    addresses = [
      "10.2.10.9/16"
      "fd2c:f4cb:63be:2::a09/64"
    ];
    mac = "0c:c4:7a:a5:a1:dc";
    mtu = 9000;
    routes = foxDenLib.hosts.helpers.lan.mkRoutes 2;
    nameservers = foxDenLib.hosts.helpers.lan.mkNameservers 2;
    interface = "br-default";
    phyIface = "ens1f0np0";
    phyPvid = 2;
    defaultDriver = "sriov";
  };
in
{
  lib.foxDenSys.mkVlanHost = foxDenLib.hosts.helpers.lan.mkVlanHost ifcfg;

  foxDen.hosts.index = 1;
  foxDen.hosts.gateway = "router";
  virtualisation.libvirtd.allowedBridges = [ ifcfg.interface ];

  systemd.network.networks."30-${ifcfg.interface}" = {
    name = ifcfg.interface;
    routes = ifcfg.routes;
    address = ifcfg.addresses;
    dns = ifcfg.nameservers;

    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = true;
    };

    bridgeVLANs = [{
      PVID = ifcfg.phyPvid;
      EgressUntagged = ifcfg.phyPvid;
      VLAN = builtins.toString ifcfg.phyPvid;
    }];

    linkConfig = {
      MTUBytes = ifcfg.mtu;
    };
  };
  #boot.initrd.systemd.network.networks."30-${ifcfg.phyIface}" = config.systemd.network.networks."30-${ifcfg.interface}" // { name = ifcfg.phyIface; };

  systemd.network.netdevs."${ifcfg.interface}" = {
    netdevConfig = {
      Name = ifcfg.interface;
      Kind = "bridge";
      MACAddress = ifcfg.mac;
    };

    bridgeConfig = {
      VLANFiltering = true;
    };
  };

  systemd.network.networks."40-${ifcfg.interface}-root" = {
    name = ifcfg.phyIface;
    bridge = [ifcfg.interface];

    bridgeVLANs = [{
      PVID = ifcfg.phyPvid;
      EgressUntagged = ifcfg.phyPvid;
      VLAN = "1-10";
    }];

    linkConfig = {
      MTUBytes = ifcfg.mtu;
    };
  };

  foxDen.hosts.hosts = {
    bengalfox = {
      interfaces.default = {
        driver = "null";
        dns = {
          name = "bengalfox.foxden.network";
        };
        addresses = ifcfg.addresses;
      };
    };
  };
}
