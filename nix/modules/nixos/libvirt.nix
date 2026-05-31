{
  hostName,
  pkgs,
  lib,
  ...
}:
let
  vmDirPath = ../../vms/${hostName};

  mkUSBDevice = dev: ''
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x${dev.vendorId}'/>
        <product id='0x${dev.productId}'/>
      </source>
    </hostdev>
  '';

  vmNames =
    let
      vmDir = if (builtins.pathExists vmDirPath) then (builtins.readDir vmDirPath) else { };
    in
    lib.attrsets.attrNames vmDir;

  vms = lib.attrsets.genAttrs vmNames (name: rec {
    inherit name;
    # TODO: Validate this somehow
    config = import (vmDirPath + "/${name}/config.nix");

    libvirtXml = pkgs.writeText "${name}-libvirt.xml" (
      lib.replaceString "<devices>\n" "<devices>\n${
        lib.concatStrings (map mkUSBDevice (config.devices.usb or [ ]))
      }" (builtins.readFile (vmDirPath + "/${name}/libvirt.xml"))
    );
  });
  vmList = lib.attrsets.attrValues vms;

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

  mkUSBDeviceXml = dev: pkgs.writeText "attach-usb-device.xml" (mkUSBDevice dev);
  mkVMUdevRules =
    vm:
    lib.concatStringsSep "\n" (
      map (
        dev:
        "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"${dev.vendorId}\", ATTRS{idProduct}==\"${dev.productId}\" RUN+=\"${pkgs.libvirt}/bin/virsh attach-device ${vm.name} ${mkUSBDeviceXml dev}\""
      ) (vm.config.devices.usb or [ ])
    );
in
{
  config = lib.mkIf ((lib.length vmNames) > 0) {
    services.cockpit.plugins = [ pkgs.cockpit-machines ];
    environment.systemPackages = with pkgs; [ virt-manager ];

    virtualisation.libvirtd = {
      enable = true;
      dbus.enable = true;
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
          ExecStart = map setupVMScript vmList;
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
      }) (lib.filter (vm: vm.config.autostart) vmList)
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

    services.udev.extraRules = lib.concatStringsSep "\n" (map mkVMUdevRules vmList);

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

    foxDen.dns.records = lib.mkMerge (map (vm: vm.config.records or [ ]) vmList);
  };
}
