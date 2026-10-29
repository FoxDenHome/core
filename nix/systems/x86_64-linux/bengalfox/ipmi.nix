{ config, ... }:
{
  # oauth-jit-radius has a matcher for this BMC.
  config.foxDen.hosts.hosts.${config.foxDen.ipmiconfig.network.hostName}.launcher.webUI.radius = true;

  # Gateway, IPv6 address, DNS and NTP follow from the VLAN
  config.foxDen.ipmiconfig = {
    enable = true;
    acme.enable = true;
    network = {
      mac = "00:25:90:FF:CF:5B";
      vlan = 1;
      ipv4.address = "10.1.12.1/16";
    };
  };
}
