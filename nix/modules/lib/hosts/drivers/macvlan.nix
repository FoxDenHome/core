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

  # The macvlan (and the VLAN device under it, where there is one) hangs off
  # the root link, so nothing here can be created before that link exists.
  rootDevices = interface: [ interface.driver.macvlan.root ];

  hooks = (
    {
      ipCmd,
      interface,
      pkgs,
      uniqueServiceInterface,
      ...
    }:
    let
      cfg = interface.driver.macvlan;
      vlanIface = mkVlanIface cfg;

      # The root link's device unit shows up as soon as the link exists, but
      # its MTU is only raised once networkd gets around to configuring it.
      # Until then neither the VLAN device nor the macvlan can take our MTU.
      waitMtuScript = pkgs.writeShellScript "wait-macvlan-mtu.sh" ''
        set -euo pipefail
        mtu_file="/sys/class/net/$1/mtu"
        maxtries=600
        while [ "$(${pkgs.coreutils}/bin/cat "$mtu_file" 2>/dev/null || echo 0)" -lt "$2" ]; do
          maxtries=$((maxtries - 1))
          if [ $maxtries -le 0 ]; then
            echo "Timeout waiting for $1 to reach MTU $2" >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/sleep 0.1
        done
      '';
    in
    {
      start =
        [
          "${waitMtuScript} ${eSA cfg.root} ${toString cfg.mtu}"
        ]
        ++ (lib.lists.optionals (!(isPvid cfg)) [
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
