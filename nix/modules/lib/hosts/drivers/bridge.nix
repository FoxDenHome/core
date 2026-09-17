{ nixpkgs, ... }:
let
  eSA = nixpkgs.lib.strings.escapeShellArg;

  mkIfaceName = (iface: "vebr${iface.suffix}");
in
{
  driverConfigType =
    with nixpkgs.lib.types;
    submodule {
      options = {
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
    };

  build =
    { interfaces, ... }:
    {
      config.systemd.network.networks = nixpkgs.lib.attrsets.listToAttrs (
        map (
          iface:
          let
            inherit (iface.driver.bridge) vlan;
          in
          {
            name = "60-vebr-${iface.host.name}-${iface.name}";
            value = {
              name = mkIfaceName iface;
              bridge = [ iface.driver.bridge.bridge ];
              bridgeVLANs =
                if (vlan > 0) then
                  [
                    {
                      PVID = vlan;
                      EgressUntagged = vlan;
                      VLAN = vlan;
                    }
                  ]
                else
                  [ ];
              bridgeConfig = {
                UseBPDU = false;
                AllowPortToBeRoot = false;
              };
              linkConfig = {
                MTUBytes = iface.driver.bridge.mtu;
              };
            };
          }
        ) interfaces
      );
    };

  hooks = (
    {
      ipCmd,
      interface,
      pkgs,
      uniqueServiceInterface,
      ...
    }:
    let
      hostIface = mkIfaceName interface;
      ethtool = eSA "${pkgs.ethtool}/bin/ethtool";
    in
    {
      start = [
        "-${ipCmd} link del ${eSA hostIface}"
        "${ipCmd} link add ${eSA hostIface} type veth peer name ${eSA uniqueServiceInterface}"
        "${ipCmd} link set dev ${eSA hostIface} mtu ${toString interface.driver.bridge.mtu}"
        "${ipCmd} link set dev ${eSA uniqueServiceInterface} mtu ${toString interface.driver.bridge.mtu}"
        "-${ethtool} -K ${eSA hostIface} gro on"
        "-${ethtool} -K ${eSA uniqueServiceInterface} gro on"
      ];
      stop = [
        "-${ipCmd} link del ${eSA hostIface}"
      ];
    }
  );
}
