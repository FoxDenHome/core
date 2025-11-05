{ foxDenLib, ... }:
{
  config.foxDen.hosts.hosts = let
    mkIntf = (intf: {
      interfaces.default = { driver.name = "null"; } // intf;
    });
  in {
    bambu-x1 = mkIntf {
      dns = {
        name = "bambu-x1.foxden.network";
      };
      firewall.ingressAcceptRules = foxDenLib.firewall.templates.trusted "bambu-x1";
      mac = "08:FB:EA:02:64:96";
      addresses = [
        "10.4.10.1/16"
      ];
    };
    carvera = mkIntf {
      dns = {
        name = "carvera.foxden.network";
      };
      mac = "EC:C7:00:1C:E3:2D";
      addresses = [
        "10.4.10.3/16"
      ];
    };
    carvera-controller = mkIntf {
      dns = {
        name = "carvera-controller.foxden.network";
      };
      mac = "6C:6E:07:1B:1D:24";
      dhcpv6 = {
        duid = "0x00020000ab1122f2d239e0457e9d";
        iaid = 886453245;
      };
      addresses = [
        "10.4.10.2/16"
        "fd2c:f4cb:63be:4::a02/64"
      ];
    };
    laser-controller = mkIntf {
      dns = {
        name = "laser-controller.foxden.network";
      };
      mac = "8C:16:45:46:05:22";
      addresses = [
        "10.4.10.5/16"
      ];
    };
  };
}
