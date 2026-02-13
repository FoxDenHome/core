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
      mister = mkIntf {
        dns = {
          fqdns = [ "mister.foxden.network" ];
        };
        mac = "02:03:04:05:06:07";
        addresses = [
          "10.7.10.1/24"
        ];
      };
      ps2 = mkIntf {
        dns = {
          fqdns = [ "ps2.foxden.network" ];
        };
        mac = "00:27:09:FF:A7:49";
        addresses = [
          "10.7.10.2/24"
        ];
      };
      n3ds = mkIntf {
        dns = {
          fqdns = [ "n3ds.foxden.network" ];
        };
        mac = "04:03:D6:71:42:1A";
        addresses = [
          "10.7.10.3/24"
        ];
      };
      ps4 = mkIntf {
        dns = {
          fqdns = [ "ps4.foxden.network" ];
        };
        mac = "0C:FE:45:59:61:38";
        addresses = [
          "10.7.10.4/24"
        ];
      };
      wii = mkIntf {
        dns = {
          fqdns = [ "wii.foxden.network" ];
        };
        mac = "00:27:09:8A:A7:49";
        addresses = [
          "10.7.10.7/24"
        ];
      };
    };
}
