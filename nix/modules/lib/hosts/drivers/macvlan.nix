{ nixpkgs, ... }:
let
  lib = nixpkgs.lib;
  eSA = lib.strings.escapeShellArg;
in
{
  driverConfigType =
    with lib.types;
    submodule {
      options = {
        vlan = lib.mkOption {
          type = ints.unsigned;
        };
        root = lib.mkOption {
          type = str;
        };
        mtu = lib.mkOption {
          type = ints.u16;
          default = 1500;
        };
      };
    };

  build =
    { ... }:
    {
      config.systemd = { };
    };

  hooks = (
    {
      ipCmd,
      interface,
      uniqueServiceInterface,
      ...
    }:
    let
      cfg = interface.driver.macvlan;
      vlanIface = if cfg.vlan == 0 then cfg.root else "${cfg.root}.${toString cfg.vlan}";
    in
    {
      start =
        # The VLAN device is shared by every host on it and never torn down,
        # so whoever gets there first creates it.
        (lib.lists.optionals (cfg.vlan != 0) [
          "-${ipCmd} link add link ${eSA cfg.root} name ${eSA vlanIface} type vlan id ${toString cfg.vlan}"
          "${ipCmd} link set dev ${eSA vlanIface} mtu ${toString cfg.mtu} up"
        ])
        ++ [
          "-${ipCmd} link del ${eSA uniqueServiceInterface}"
          "${ipCmd} link add link ${eSA vlanIface} name ${eSA uniqueServiceInterface} type macvlan mode bridge"
          "${ipCmd} link set dev ${eSA uniqueServiceInterface} mtu ${toString cfg.mtu}"
        ];
      stop = [
        "-${ipCmd} link del ${eSA uniqueServiceInterface}"
      ];
    }
  );
}
