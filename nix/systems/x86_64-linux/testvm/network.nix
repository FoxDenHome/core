{ ... }:
{
  foxDen.hosts.index = 255;
  foxDen.hosts.gateway = "local";

  systemd.network.networks."30-eth0" = {
    name = "eth0";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };
}
