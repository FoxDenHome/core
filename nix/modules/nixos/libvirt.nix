{ hostName, pkgs, lib, ... }:
let
  vmDirPath = ../../vms/${hostName};

  vmNames = let
    vmDir = if (builtins.pathExists vmDirPath) then (builtins.readDir vmDirPath) else {};
  in lib.attrsets.attrNames vmDir;

  vms = lib.attrsets.genAttrs vmNames (name: {
    inherit name;
    # TODO: Validate this somehow
    config = import (vmDirPath+"/${name}/config.nix");
    libvirtXml = vmDirPath+"/${name}/libvirt.xml";
  });

  setupVMScript = vm: pkgs.writeShellScript "setup-vm" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    if [ ! -f /var/lib/libvirt/images/${vm.name}.qcow2 ]; then
      echo "Creating root disk for ${vm.name}"
      ${pkgs.qemu-utils}/bin/qemu-img create -f qcow2 /var/lib/libvirt/images/${vm.name}.qcow2 ${vm.config.rootDiskSize}
    fi
    ${pkgs.coreutils}/bin/chown -h qemu-libvirtd:qemu-libvirtd /var/lib/libvirt/images/${vm.name}.qcow2
    ${pkgs.libvirt}/bin/virsh define ${vm.libvirtXml}
    ${pkgs.libvirt}/bin/virsh autostart ${vm.name} --disable
  '';

  setupSriovScriptRawIface = vm: ifaceName: pkgs.writeShellScript "setup-sriov" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    physfn='/sys/bus/pci/devices/${vm.config.sriovMappings.${ifaceName}.addr}/physfn'
    physdev="$(${pkgs.coreutils}/bin/ls "$physfn/net")"

    numvfs_file="/sys/class/net/$physdev/device/sriov_numvfs"
    totalvfs="$(cat /sys/class/net/$physdev/device/sriov_totalvfs)"
    numvfs="$(cat "$numvfs_file")"
    if [ "$numvfs" -eq 0 ]; then
      echo $totalvfs > "$numvfs_file"
    fi

    for vfn in $physfn/virtfn*; do
      vfn_dev="$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink "$vfn")")"
      if [ "$vfn_dev" == "${vm.config.sriovMappings.${ifaceName}.addr}" ]; then
        vfn_idx="$(${pkgs.coreutils}/bin/basename "$vfn" | ${pkgs.gnused}/bin/sed 's/virtfn//')"
        echo "Configuring SR-IOV for VM ${vm.name} on device phy=$physdev vfidx=$vfn_idx vfdev=$vfn_dev"
        ${pkgs.iproute2}/bin/ip link set "$physdev" vf "$vfn_idx" mac "${vm.config.interfaces.${ifaceName}.mac}" spoofchk on vlan ${toString vm.config.sriovMappings.${ifaceName}.vlan}
        exit 0
      fi
    done
  '';
  setupSriovScripts = vm: map (ifaceName: "${pkgs.util-linux}/bin/flock -x /run/foxden-sriov.lock '${setupSriovScriptRawIface vm ifaceName}'") (lib.attrsets.attrNames (vm.config.sriovMappings or {}));
  sriovExecStarts = lib.flatten (map setupSriovScripts (lib.attrsets.attrValues vms));
in
{
  config = lib.mkIf ((lib.length vmNames) > 0) {
    virtualisation.libvirtd = {
      enable = true;
      onShutdown = "shutdown";
      onBoot = "ignore";
      qemu = {
        vhostUserPackages = [ pkgs.virtiofsd ];
        package = pkgs.qemu_kvm;
        runAsRoot = false;
        swtpm.enable = true;
        ovmf = {
          enable = true;
        };
      };
    };

    systemd.services = {
      libvirt-sriov-pre = {
        description = "Libvirt SR-IOV Pre-Setup Service";
        before = [ "libvirtd.service" ];
        requiredBy = [ "libvirtd.service" ];
        enable = (lib.lists.length sriovExecStarts) > 0;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = sriovExecStarts;
          TimeoutStartSec = "5min";
          RemainAfterExit = true;
        };
        wantedBy = [ "multi-user.target" ];
      };
      libvirt-autocreator = {
        description = "Libvirt AutoCreator Service";
        after = [ "libvirtd.service" ];
        requires = [ "libvirtd.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/lib/libvirt/images";
          ExecStart = map setupVMScript (lib.attrsets.attrValues vms);
          RemainAfterExit = true;
        };
        wantedBy = [ "multi-user.target" ];
      };
    } // lib.attrsets.listToAttrs (map (vm: {
      name = "libvirt-vm-${vm.name}";
      value = {
        after = [ "libvirt-autocreator.service" "libvirtd.service" ];
        requires = [ "libvirtd.service" ];
        wants = [ "libvirt-autocreator.service" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = [
            "-${pkgs.libvirt}/bin/virsh start ${vm.name}"
          ];
          RemainAfterExit = true;
          Restart = "no";
        };
        wantedBy = [ "multi-user.target" ];
      };
    }) (lib.attrsets.attrValues vms));

    environment.persistence."/nix/persist/libvirt" = {
      hideMounts = true;
      directories = [
        { directory = "/var/lib/libvirt"; user = "qemu-libvirtd"; group = "qemu-libvirtd"; mode = "u=rwx,g=,o="; }
      ];
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.libvirt.unix.manage" &&
          subject.isInGroup("superadmins")) {
          return polkit.Result.YES;
        }
      });
    '';

    foxDen.hosts.hosts = lib.attrsets.genAttrs vmNames (name: {
      interfaces = lib.attrsets.mapAttrs (_: iface: { driver.name = "null"; useDHCP = true; } // iface) vms.${name}.config.interfaces;
      webservice = vms.${name}.config.webservice or {};
    });

    foxDen.dns.records = lib.mkMerge (map (vm: vm.config.records or []) (lib.attrsets.attrValues vms));
  };
}
