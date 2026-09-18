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
    interface = "ens1np0";
    phyIface = "ens1np0";
    phyPvid = 2;
    mtu = 9000;
    mac = config.lib.foxDen.mkHashMac "000001";
    defaultDriver = "macvlan";
  };
  hostIface = "sys-${ifcfg.phyIface}";
in
{
  lib.foxDenSys.mkVlanHost = foxDenLib.hosts.helpers.lan.mkVlanHost ifcfg;

  foxDen.hosts.index = 2;
  foxDen.hosts.gateway = "router";

  systemd.network.netdevs."${hostIface}" = {
    netdevConfig = {
      Name = hostIface;
      Kind = "macvlan";
      MACAddress = ifcfg.mac;
      MTUBytes = ifcfg.mtu;
    };

    macvlanConfig = {
      Mode = "bridge";
    };
  };

  systemd.network.networks."30-${hostIface}" = {
    name = hostIface;
    routes = ifcfg.routes;
    address = ifcfg.addresses;
    dns = ifcfg.nameservers;

    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = true;
    };

    linkConfig = {
      MTUBytes = ifcfg.mtu;
    };
  };

  systemd.network.networks."30-${ifcfg.interface}" = {
    name = ifcfg.interface;
    macvlan = [ hostIface ];

    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };

    linkConfig = {
      MTUBytes = ifcfg.mtu;
    };
  };
  #boot.initrd.systemd.network.networks."30-${ifcfg.interface}" = config.systemd.network.networks."30-${ifcfg.interface}";

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
