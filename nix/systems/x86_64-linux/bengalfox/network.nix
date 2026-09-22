{ foxDenLib, config, ... }:
let
  ifcfg = {
    addresses = [
      "10.2.10.9/16"
      "fd2c:f4cb:63be:2::a09/64"
    ];
    mac = config.lib.foxDen.mkHashMac "000001";
    mtu = 9000;
    routes = foxDenLib.hosts.helpers.lan.mkRoutes 2;
    nameservers = foxDenLib.hosts.helpers.lan.mkNameservers 2;
    interface = "ens1f0np0";
    phyIface = "ens1f0np0";
    phyPvid = 2;
    defaultDriver = "sriov";
  };
in
{
  lib.foxDenSys.mkVlanHost = foxDenLib.hosts.helpers.lan.mkVlanHost ifcfg;

  foxDen.hosts.index = 1;
  foxDen.hosts.gateway = "router";
  foxDen.services.tlsHardwareAcceleration = true;

  systemd.network.networks."30-${ifcfg.interface}" = {
    name = ifcfg.interface;
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
  #boot.initrd.systemd.network.networks."30-${ifcfg.interface}" = config.systemd.network.networks."30-${ifcfg.interface}";

  foxDen.servicesptp = {
    enable = true;
    interface = ifcfg.interface;
  };

  foxDen.hosts.hosts = {
    bengalfox = {
      ssh = true;
      interfaces.default = {
        driver.name = "null";
        dns = {
          fqdns = [ "bengalfox.foxden.network" ];
        };
        email.allowedFrom = [ "bengalfox@foxden.network" ];
        inherit (ifcfg) mac addresses;
      };
    };
  };
}
