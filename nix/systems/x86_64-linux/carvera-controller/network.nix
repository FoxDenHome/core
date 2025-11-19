{ foxDenLib, ... }:
let
  ifcfg = {
    addresses = [
      "10.4.10.2/16"
      "fd2c:f4cb:63be:4::a02/64"
    ];
    mtu = 9000;
    routes = foxDenLib.hosts.helpers.lan.mkRoutes 4;
    nameservers = foxDenLib.hosts.helpers.lan.mkNameservers 4;
    interface = "enp0s20f0u3u3";
  };
in
{
  foxDen.hosts.index = 5;
  foxDen.hosts.gateway = "router";

  services.avahi.enable = true;

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
  #boot.initrd.systemd.network.networks."30-${ifcfg.phyIface}" = config.systemd.network.networks."30-${ifcfg.interface}" // { name = ifcfg.phyIface; };

  foxDen.hosts.hosts = {
    carvera-controller = {
      ssh = true;
      interfaces.default = {
        driver.name = "null";
        dns = {
          fqdns = [ "carvera-controller.foxden.network" ];
        };
        inherit (ifcfg) addresses;
      };
    };
  };
}
