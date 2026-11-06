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
      laser-controller = mkIntf {
        dns = {
          fqdns = [ "laser-controller.foxden.network" ];
        };
        mac = "8C:16:45:46:05:22";
        addresses = [
          "10.4.10.5/16"
        ];
      };
    };
}
