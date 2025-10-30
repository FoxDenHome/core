{ nixpkgs, ... } :
{
  driverOptsType = with nixpkgs.lib.types; submodule {
    vlan = nixpkgs.lib.mkOption {
      type = ints.unsigned;
    };
    rootPvid = nixpkgs.lib.mkOption {
      type = ints.unsigned;
    };
    root = nixpkgs.lib.mkOption {
      type = str;
    };
  };

  build = { ... } : {
    config.systemd = {};
  };

  hooks = ({ pkgs, ipCmd, serviceInterface, interface, ... }: let
    root = interface.driverOpts.root;

    vlan = if interface.driverOpts.vlan == interface.driverOpts.rootPvid then 0 else interface.driverOpts.vlan;

    allocSriovScript = pkgs.writeShellScript "allocate-sriov" ''
      set -euox pipefail
      interface="$1"
      numvfs_file="/sys/class/net/${root}/device/sriov_numvfs"
      totalvfs="$(cat /sys/class/net/${root}/device/sriov_totalvfs)"
      numvfs="$(cat "$numvfs_file")"
      if [ "$numvfs" -eq 0 ]; then
        echo $totalvfs > "$numvfs_file"
      fi

      assign_vf() {
        idx="$1"
        # Enable spoof checking, set MAC and VLAN
        ${ipCmd} link set dev "${root}" vf "$idx" spoofchk on mac "${interface.mac}" vlan "${builtins.toString vlan}"
        # Find current name of VF interface
        ifname="$(${pkgs.coreutils}/bin/ls /sys/class/net/${root}/device/virtfn$idx/net/)"
        # And rename it
        ${ipCmd} link set dev "$ifname" name "${serviceInterface}"
      }

      assign_vf_by_mac() {
        mac="$1"
        matched_vf="$(${ipCmd} link show dev "${root}" | ${pkgs.gnugrep}/bin/grep -oi "vf .* link/ether $mac " | ${pkgs.coreutils}/bin/cut -d' ' -f2 | ${pkgs.coreutils}/bin/head -1 || :)"
        if [ -n "$matched_vf" ]; then
          assign_vf "$matched_vf"
          exit 0
        fi
      }

      # Condition A: We find a VIF with our MAC address
      assign_vf_by_mac '${interface.mac}'

      # Condition B: Find an unused VF
      assign_vf_by_mac '00:00:00:00:00:00'

      # Condition C: No free VFs, go hunting for unused ones (in main netns)
      for i in `seq 0 $(( $numvfs - 1 ))`; do
        # If the interface is listed here with its name, it is in the root NS, so it is unused
        ifname="$(${pkgs.coreutils}/bin/ls /sys/class/net/${root}/device/virtfn$i/net/)"
        if [ -n "$ifname" ]; then
          assign_vf "$i"
          exit 0
        fi
      done

      # Condition D: No VFs available
      exit 1
    '';
  in
  {
    start = [
      "${pkgs.util-linux}/bin/flock -x /run/foxden-sriov.lock '${allocSriovScript}' '${root}'"
    ];
    serviceInterface = "";
    stop = [
    ];
  });
}
