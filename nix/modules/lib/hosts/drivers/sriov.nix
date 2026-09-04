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
        rootPvid = nixpkgs.lib.mkOption {
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
    { ... }:
    {
      config.systemd = { };
    };

  hooks = (
    {
      pkgs,
      ipCmd,
      uniqueServiceInterface,
      interface,
      host,
      rootNetnsInterfaces,
      ...
    }:
    let
      root = interface.driver.sriov.root;

      vlan =
        if interface.driver.sriov.vlan == interface.driver.sriov.rootPvid then
          0
        else
          interface.driver.sriov.vlan;

      ethtoolCmd = "${pkgs.ethtool}/bin/ethtool";

      allocSriovScript = pkgs.writeShellScript "allocate-sriov.sh" ''
        #!${pkgs.bash}/bin/bash
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
          ifname=""
          maxtries=300
          while :; do
            ifname="$(${pkgs.coreutils}/bin/ls /sys/class/net/${root}/device/virtfn$idx/net/ 2>/dev/null || :)"
            if [ -n "$ifname" ]; then
              break
            fi
            maxtries=$((maxtries - 1))
            if [ $maxtries -le 0 ]; then
              echo "Timeout waiting for VF interface to appear" >&2
              exit 1
            fi
            sleep 0.1
          done
          # And rename it, unless it already carries the name (a VF we keep
          # in the root netns still does after a restart)
          if [ "$ifname" != "${uniqueServiceInterface}" ]; then
            ${ipCmd} link set dev "$ifname" down
            ${ipCmd} link set dev "$ifname" name "${uniqueServiceInterface}"
            ifname="${uniqueServiceInterface}"
          fi
          ${ethtoolCmd} -K "${uniqueServiceInterface}" tls-hw-tx-offload on || true
          ${ethtoolCmd} -K "${uniqueServiceInterface}" tls-hw-rx-offload on || true

          # RDMA, if present
          rdma_link_name="$(${pkgs.iproute2}/bin/rdma link show | grep "netdev $ifname\\s" | cut -d' ' -f2 | cut -d/ -f1 || :)"
          if [ -n "$rdma_link_name" ]; then
            if [ "$rdma_link_name" != "${uniqueServiceInterface}" ]; then
              ${pkgs.iproute2}/bin/rdma dev set "$rdma_link_name" name "${uniqueServiceInterface}"
            fi
            ${
              # Root netns interfaces keep their RDMA device where it is,
              # which is the only place SMB Direct and friends can see it.
              if host.namespace == null then
                ":"
              else
                ''${pkgs.iproute2}/bin/rdma dev set "${uniqueServiceInterface}" netns "${host.namespace}"''
            }
          fi
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
          # If the interface is listed here with its name, it is in the root
          # NS, so it is unused - unless it is one we manage there ourselves
          ifname="$(${pkgs.coreutils}/bin/ls /sys/class/net/${root}/device/virtfn$i/net/ 2>/dev/null || :)"
          if [ -z "$ifname" ]; then
            continue
          fi
          case " ${builtins.concatStringsSep " " rootNetnsInterfaces} " in
            *" $ifname "*) continue ;;
          esac
          assign_vf "$i"
          exit 0
        done

        # Condition D: No VFs available
        exit 1
      '';
    in
    {
      start = [
        "${pkgs.util-linux}/bin/flock -x /run/foxden-sriov.lock '${allocSriovScript}' '${root}'"
        "${ipCmd} link set dev ${eSA uniqueServiceInterface} mtu ${toString interface.driver.sriov.mtu}"
      ];
      stop = [
      ];
    }
  );
}
