{
  hostName,
  pkgs,
  lib,
  ...
}:
let
  vmDirPath = ../../vms/${hostName};

  vmNames =
    let
      vmDir = if (builtins.pathExists vmDirPath) then (builtins.readDir vmDirPath) else { };
    in
    lib.attrsets.attrNames vmDir;

  vms = lib.attrsets.genAttrs vmNames (name: {
    inherit name;
    # TODO: Validate this somehow
    config = import (vmDirPath + "/${name}/config.nix");
    libvirtXml = vmDirPath + "/${name}/libvirt.xml";
  });

  setupVMScript =
    vm:
    pkgs.writeShellScript "setup-vm" ''
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
      };
    };

    systemd.services = {
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
    }
    // lib.attrsets.listToAttrs (
      map (vm: {
        name = "libvirt-vm-${vm.name}";
        value = {
          after = [
            "libvirt-autocreator.service"
            "libvirtd.service"
          ];
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
      }) (lib.attrsets.attrValues vms)
    );

    environment.persistence."/nix/persist/libvirt" = {
      hideMounts = true;
      directories = [
        {
          directory = "/var/lib/libvirt";
          user = "qemu-libvirtd";
          group = "qemu-libvirtd";
          mode = "u=rwx,g=,o=";
        }
      ];
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.libvirt.unix.manage" &&
          subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';

    foxDen.hosts.hosts = lib.attrsets.genAttrs vmNames (name: {
      interfaces = lib.attrsets.mapAttrs (
        _: iface:
        {
          driver.name = "null";
          useDHCP = true;
        }
        // iface
      ) vms.${name}.config.interfaces;
      webservice = vms.${name}.config.webservice or { };
    });

    foxDen.dns.records = lib.mkMerge (map (vm: vm.config.records or [ ]) (lib.attrsets.attrValues vms));
  };
}
