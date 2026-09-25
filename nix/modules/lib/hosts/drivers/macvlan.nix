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
      # Keyed by the link the macvlans hang off of: the shared VLAN device,
      # or the root itself for hosts on its PVID.
      parentIfaces = lib.lists.groupBy mkVlanIface (map (iface: iface.driver.macvlan) interfaces);
      parentMtus = lib.attrsets.mapAttrs (
        _: cfgs: lib.lists.unique (map (cfg: cfg.mtu) cfgs)
      ) parentIfaces;

      # Each host's start hook sets the parent's MTU, so all hosts on a
      # parent must agree or the last one to start wins.
      mismatched = lib.attrsets.filterAttrs (_: mtus: lib.length mtus != 1) parentMtus;

      vlanIfaces = lib.attrsets.filterAttrs (_: cfgs: !(isPvid (lib.head cfgs))) parentIfaces;
    in
    assert lib.asserts.assertMsg (mismatched == { }) (
      "macvlan hosts on the same link must share one MTU, got: "
      + lib.concatStringsSep "; " (
        lib.attrsets.mapAttrsToList (
          parent: mtus: "${parent}: ${lib.concatMapStringsSep ", " toString mtus}"
        ) mismatched
      )
    );
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
            MTUBytes = lib.head parentMtus.${vlanIface};
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

      # The root's device unit appears before networkd raises its MTU, and
      # children can't exceed it until then.
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
      start = [
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
