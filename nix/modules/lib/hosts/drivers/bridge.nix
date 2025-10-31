{ nixpkgs, ... }:
let
  eSA = nixpkgs.lib.strings.escapeShellArg;

  mkIfaceName = (iface: "vebr${iface.suffix}");
in
{
  driverOptsType = with nixpkgs.lib.types; submodule {
    vlan = nixpkgs.lib.mkOption {
      type = ints.unsigned;
    };
    bridge = nixpkgs.lib.mkOption {
      type = str;
    };
    mtu = nixpkgs.lib.mkOption {
      type = ints.u16;
      default = 1500;
    };
  };

  build = { interfaces, ... }:
  {
    config.systemd.network.networks =
      nixpkgs.lib.attrsets.listToAttrs (
        (map ((iface: let
          vlan = iface.driverOpts.vlan;
        in
        {
          name = "60-vebr-${iface.host.name}-${iface.name}";
          value = {
            name = mkIfaceName iface;
            bridge = [iface.driverOpts.bridge];
            bridgeVLANs = if (vlan > 0) then [{
              PVID = vlan;
              EgressUntagged = vlan;
              VLAN = vlan;
            }] else [];
          };
          linkConfig = {
            MTUBytes = iface.driverOpts.mtu;
          };
        })) interfaces));
  };

  hooks = ({ ipCmd, interface, serviceInterface, ... }: let
    hostIface = mkIfaceName interface;
  in
  {
    start = [
      "-${ipCmd} link del ${eSA hostIface}"
      "${ipCmd} link add ${eSA hostIface} type veth peer name ${eSA serviceInterface}"
      "${ipCmd} link set dev ${eSA hostIface} mtu ${toString interface.driverOpts.mtu}"
      "${ipCmd} link set dev ${eSA serviceInterface} mtu ${toString interface.driverOpts.mtu}"
    ];
    stop = [
      "-${ipCmd} link del ${eSA hostIface}"
    ];
  });
}
