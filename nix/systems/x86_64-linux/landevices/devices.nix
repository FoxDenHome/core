{ ... }:
{
  config.foxDen.hosts.hosts = {
    remarkable.interfaces.default = {
      driver.name = "null";
      dns.fqdns = [ "remarkable.foxden.network" ];
      mac = "c0:84:7d:20:57:c0";
      addresses = [ "10.2.10.5/16" ];
    };
    ups-dori-office = {
      interfaces.default = {
        driver.name = "null";
        dns.fqdns = [ "ups-dori-office.foxden.network" ];
        mac = "00:0C:15:03:74:03";
        addresses = [ "10.1.11.3/16" ];
      };
      launcher.webUI = {
        url = "https://ups-dori-office.foxden.network/";
        radius = true;
      };
    };
  };
}
