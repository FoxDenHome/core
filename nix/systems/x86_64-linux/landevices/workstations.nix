{ ... }:
{
  config.foxDen.hosts.hosts =
    let
      mkIntf = (
        intf: {
          interfaces.default = {
            driver.name = "null";
          }
          // intf;
        }
      );
    in
    {
      capefox = {
        ssh = true;
      }
      // (mkIntf {
        dns = {
          fqdns = [ "capefox.foxden.network" ];
        };
        mac = "7c:e7:12:81:29:9b";
        addresses = [
          "10.2.10.3/16"
        ];
      });
      capefox-wired = {
        ssh = true;
      }
      // (mkIntf {
        dns = {
          fqdns = [ "capefox-wired.foxden.network" ];
        };
        mac = "00:30:93:12:12:38";
        addresses = [
          "10.2.10.4/16"
        ];
      });
      crossfox = {
        ssh = true;
      }
      // (mkIntf {
        dns = {
          fqdns = [ "crossfox.foxden.network" ];
        };
        mac = "B8:27:EB:ED:0F:4B";
        dhcpv6.disable = true;
        addresses = [
          "10.5.10.3/16"
          "fd2c:f4cb:63be:5::a03/64"
        ];
      });
      fennec = {
        ssh = true;
      }
      // (mkIntf {
        dns = {
          fqdns = [ "fennec.foxden.network" ];
        };
        mac = "08:C0:EB:62:43:18";
        addresses = [
          "10.2.10.1/16"
        ];
      });
      wizzy-desktop = mkIntf {
        dns = {
          fqdns = [ "wizzy-desktop.foxden.network" ];
        };
        mac = "08:C0:EB:BF:37:0E";
        addresses = [
          "10.2.10.2/16"
        ];
      };
    };
}
