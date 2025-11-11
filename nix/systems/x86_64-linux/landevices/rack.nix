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
          name = "pikvm-rack.foxden.network";
        };
        mac = "D8:3A:DD:A3:82:A8";
        dhcpv6 = {
          duid = "0x00020000ab114a5edad0f8fd0afa";
          iaid = 4174257057;
        };
        addresses = [
          "10.1.13.2/16"
          "fd2c:f4cb:63be:1::d02/64"
        ];
      };
      tape-library = mkIntf {
        dns = {
          name = "tape-library.foxden.network";
        };
        mac = "00:0E:11:14:70:8B";
        dhcpv6 = {
          duid = "0x00030001000e1114708b";
          iaid = 286552203;
        };
        addresses = [
          "10.1.13.1/16"
          "fd2c:f4cb:63be:1::d01/64"
        ];
      };
      ups-rack = mkIntf {
        dns = {
          name = "ups-rack.foxden.network";
        };
        dhcpv6 = {
          duid = "0x0003000100c0b7e8b2a0";
          iaid = 2;
        };
        mac = "00:C0:B7:E8:B2:A0";
        addresses = [
          "10.1.11.2/16"
          "fd2c:f4cb:63be:1::b02/64"
        ];
      };
    };
}
