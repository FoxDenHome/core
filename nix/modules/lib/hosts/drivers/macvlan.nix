{ nixpkgs, ... }:
let
  lib = nixpkgs.lib;
  eSA = lib.strings.escapeShellArg;

  # A host on the root interface's PVID rides that interface directly,
  # everyone else gets a VLAN device hung off of it.
  isPvid = cfg: cfg.vlan == cfg.rootPvid;
  mkVlanIface = cfg: if isPvid cfg then cfg.root else "${cfg.root}.${toString cfg.vlan}";
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
        rootPvid = nixpkgs.lib.mkOption {
          type = ints.unsigned;
        };
        mtu = lib.mkOption {
          type = ints.u16;
          default = 1500;
        };
      };
    };

  build =
    { interfaces, ... }:
    let
      vlanIfaces = lib.lists.groupBy mkVlanIface (
        lib.lists.filter (cfg: !(isPvid cfg)) (map (iface: iface.driver.macvlan) interfaces)
      );
    in
    {
      config.systemd.network.networks = lib.attrsets.mapAttrs' (vlanIface: cfgs: {
        name = "50-macvlan-${vlanIface}";
        value = {
          name = vlanIface;
          networkConfig = {
            DHCP = "no";
            IPv6AcceptRA = false;
            LinkLocalAddressing = "no";
          };
          linkConfig = {
            MTUBytes = lib.lists.foldl' (mtu: cfg: lib.trivial.max mtu cfg.mtu) 0 cfgs;
          };
        };
      }) vlanIfaces;
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
      vlanIface = mkVlanIface cfg;
    in
    {
      start =
        (lib.lists.optionals (!(isPvid cfg)) [
          "-${ipCmd} link add link ${eSA cfg.root} name ${eSA vlanIface} type vlan id ${toString cfg.vlan}"
          "${ipCmd} link set dev ${eSA vlanIface} mtu ${toString cfg.mtu} addrgenmode none up"
          "-${ipCmd} addr flush dev ${eSA vlanIface}"
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
