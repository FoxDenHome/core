{ ... }:
{
  config.foxDen.hosts.hosts = let
    mkIntf = (intf: {
      interfaces.default = { driver.name = "null"; } // intf;
    });
  in {
    amp-living-room = mkIntf {
      dns = {
        name = "amp-living-room.foxden.network";
      };
      mac = "EC:F4:51:D0:8C:AF";
      addresses = [
        "10.2.12.10/16"
      ];
    };
    ecoflow-delta-pro = mkIntf {
      dns = {
        name = "ecoflow-delta-pro.foxden.network";
      };
      mac = "4C:EB:D6:D6:3C:9C";
      addresses = [
        "10.2.12.31/16"
      ];
    };
    hue = mkIntf {
      dns = {
        name = "hue.foxden.network";
      };
      mac = "C4:29:96:B5:2B:8F";
      dhcpv6 = {
        duid = "0x00020000ab11a39d5ea7b078c55a";
        iaid = 1491564959;
      };
      addresses = [
        "10.2.12.1/16"
        "fd2c:f4cb:63be:2::c01/64"
      ];
    };
    hue-sync-box = mkIntf {
      dns = {
        name = "hue-sync-box.foxden.network";
      };
      mac = "C4:29:96:0B:9C:82";
      addresses = [
        "10.2.12.18/16"
      ];
    };
    led-strip-dori-office-ceiling = mkIntf {
      dns = {
        name = "led-strip-dori-office-ceiling.foxden.network";
      };
      mac = "C4:DE:E2:B2:D2:C7";
      addresses = [
        "10.2.13.21/16"
      ];
    };
    nanoleaf-shapes-dori = mkIntf {
      dns = {
        name = "nanoleaf-shapes-dori.foxden.network";
      };
      mac = "80:8A:F7:03:E2:1A";
      dhcpv6 = {
        duid = "0x00030001808af703e21a";
        iaid = 1;
      };
      addresses = [
        "10.2.12.28/16"
        "fd2c:f4cb:63be:2::c1c/64"
      ];
    };
    nanoleaf-lines-wizzy = mkIntf {
      dns = {
        name = "nanoleaf-lines-wizzy.foxden.network";
      };
      mac = "80:8A:F7:03:55:58";
      dhcpv6 = {
        duid = "0x00030001808af7035558";
        iaid = 1;
      };
      addresses = [
        "10.2.12.19/16"
        "fd2c:f4cb:63be:2::c13/64"
      ];
    };
    printer = mkIntf {
      dns = {
        name = "printer.foxden.network";
      };
      mac = "64:C6:D2:E5:91:45";
      addresses = [
        "10.2.12.3/16"
      ];
    };
    streamdeckpi = mkIntf {
      dns = {
        name = "streamdeckpi.foxden.network";
      };
      mac = "D8:3A:DD:40:CA:F1";
      addresses = [
        "10.2.12.30/16"
      ];
    };
    tesla-wall-charger = mkIntf {
      dns = {
        name = "tesla-wall-charger.foxden.network";
      };
      mac = "98:ED:5C:9B:79:CF";
      addresses = [
        "10.2.12.16/16"
      ];
    };
    ups-dori-office = mkIntf {
      dns = {
        name = "ups-dori-office.foxden.network";
      };
      mac = "00:0C:15:04:39:93";
      dhcpv6 = {
        duid = "0x00030001000c15043993";
        iaid = 167781915;
      };
      addresses = [
        "10.1.11.3/16"
        "fd2c:f4cb:63be:1::b03/64"
      ];
    };
  };
}
