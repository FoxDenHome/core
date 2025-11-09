{ ... }:
{
  config.foxDen.hosts.hosts = let
    mkIntf = (intf: {
      interfaces.default = { driver.name = "null"; } // intf;
    });
  in {
    capefox = {
      ssh = true;
    } // (mkIntf {
      dns = {
        name = "capefox.foxden.network";
      };
      mac = "7c:e7:12:81:29:9b";
      dhcpv6 = {
        duid = "0x000100012d6265636c7e67bcff75";
        iaid = 0;
      };
      addresses = [
        "10.2.10.3/16"
        "fd2c:f4cb:63be:2::a03/64"
      ];
    });
    capefox-wired = mkIntf {
      dns = {
        name = "capefox-wired.foxden.network";
      };
      mac = "00:30:93:12:12:38";
      addresses = [
        "10.2.10.4/16"
      ];
    };
    crossfox = {
      ssh = true;
    } // (mkIntf {
      dns = {
        name = "crossfox.foxden.network";
      };
      mac = "B8:27:EB:ED:0F:4B";
      dhcpv6 = {
        duid = "0x0004e6fce6a5d4ed3d40b052d913277bff9c";
        iaid = 726689589;
      };
      addresses = [
        "10.5.10.3/16"
        "fd2c:f4cb:63be:5::a03/64"
      ];
    });
    fennec = {
      ssh = true;
    } // (mkIntf {
      dns = {
        name = "fennec.foxden.network";
      };
      mac = "7C:FE:90:31:7B:0E";
      dhcpv6 = {
        duid = "0x0004f480d71b42f7092a0657194834b9505d";
        iaid = 876325795;
      };
      addresses = [
        "10.2.10.1/16"
        "fd2c:f4cb:63be:2::a01/64"
      ];
    });
    wizzy-desktop = mkIntf {
      dns = {
        name = "wizzy-desktop.foxden.network";
      };
      mac = "7C:FE:90:39:20:9A";
      dhcpv6 = {
        duid = "0x000100013060c3d8ec9161cff6c9";
        iaid = 494730896;
      };
      addresses = [
        "10.2.10.2/16"
        "fd2c:f4cb:63be:2::a02/64"
      ];
    };
  };
}
