{
  foxDenLib,
  pkgs,
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
    phyIface = "ens1np0";
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

  networking.firewall = {
    allowedUDPPorts = [ 9 ];
  };
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", NAME=="${ifcfg.phyIface}", RUN+="${pkgs.ethtool}/bin/ethtool -s ${ifcfg.phyIface} wol g"
  '';

  systemd.network.networks."30-${ifcfg.interface}" = {
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
        VLAN = builtins.toString ifcfg.phyPvid;
      }
    ];

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
    bridge = [ ifcfg.interface ];

    bridgeVLANs = [
      {
        PVID = ifcfg.phyPvid;
        EgressUntagged = ifcfg.phyPvid;
        VLAN = "1-9";
      }
      {
        VLAN = "2001";
      }
    ];

    linkConfig = {
      MTUBytes = ifcfg.mtu;
    };
  };

  foxDen.networking.provisionCriticalHosts = true;

  foxDen.hosts.hosts = {
    islandfox = {
      ssh = true;
      interfaces.default = {
        driver.name = "null";
        dns = {
          fqdns = [ "islandfox.foxden.network" ];
        };
        inherit (ifcfg) mac addresses;
      };
    };
  };
}
