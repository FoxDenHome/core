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
      pikvm-rack = mkIntf {
        dns = {
          fqdns = [ "pikvm-rack.foxden.network" ];
        };
        mac = "D8:3A:DD:A3:82:A8";
        addresses = [
          "10.1.13.2/16"
        ];
      };
      tape-library = mkIntf {
        dns = {
          fqdns = [ "tape-library.foxden.network" ];
        };
        mac = "00:0E:11:14:70:8B";
        addresses = [
          "10.1.13.1/16"
        ];
      };
      ups-rack = mkIntf {
        dns = {
          fqdns = [ "ups-rack.foxden.network" ];
        };
        mac = "00:20:85:DB:92:BA";
        addresses = [
          "10.1.11.2/16"
        ];
      };
      ats-rack = mkIntf {
        dns = {
          fqdns = [ "ats-rack.foxden.network" ];
        };
        mac = "00:0C:15:04:39:93";
        addresses = [
          "10.1.11.4/16"
        ];
      };
    };
}
