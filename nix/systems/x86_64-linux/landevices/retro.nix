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
          fqdn = "mister.foxden.network";
        };
        mac = "02:03:04:05:06:07";
        addresses = [
          "100.96.41.253/24"
        ];
      };
      ps2 = mkIntf {
        dns = {
          fqdn = "ps2.foxden.network";
        };
        mac = "00:27:09:FF:A7:49";
        addresses = [
          "100.96.41.102/24"
        ];
      };
      wii = mkIntf {
        dns = {
          fqdn = "wii.foxden.network";
        };
        mac = "00:27:09:8A:A7:49";
        addresses = [
          "100.96.41.101/24"
        ];
      };
    };
}
