{ nixpkgs, ... }:
let
  eSA = nixpkgs.lib.strings.escapeShellArg;
in
{
  driverConfigType =
    with nixpkgs.lib.types;
    submodule {
      options = {
        vlan = nixpkgs.lib.mkOption {
          type = ints.unsigned;
        };
        root = nixpkgs.lib.mkOption {
          type = str;
        };
        mtu = nixpkgs.lib.mkOption {
          type = ints.u16;
          default = 1500;
        };
      };
    };

  build =
    { interfaces, ... }:
    {
      config.systemd.network.netdevs = nixpkgs.lib.attrsets.listToAttrs (
        map (iface: {
          name = "${iface.driver.macvlan.root}.${toString iface.driver.macvlan.vlan}";
          value = {
            name = "${iface.driver.macvlan.root}.${toString iface.driver.macvlan.vlan}";
            kind = "vlan";
            vlanConfig = {
              id = iface.driver.macvlan.vlan;
            };
          };
        }) interfaces
      );
    };

  hooks = (
    {
      ipCmd,
      interface,
      uniqueServiceInterface,
      ...
    }:
    {
      start = [
        "-${ipCmd} link del ${eSA uniqueServiceInterface}"
        "${ipCmd} link add link ${interface.driver.maclvan.root} name ${eSA uniqueServiceInterface} type macvlan mode bridge"
        "${ipCmd} link set dev ${eSA uniqueServiceInterface} mtu ${toString interface.driver.maclvan.mtu}"
      ];
      stop = [
        "-${ipCmd} link del ${eSA uniqueServiceInterface}"
      ];
    }
  );
}
