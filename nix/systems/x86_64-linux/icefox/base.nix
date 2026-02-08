{ config, ... }:
{
  # These are set when you reinstall the system
  # Change them to "false" for first boot, before secrets exist
  # then, once stuff is done, set them to true
  foxDen.sops.available = true;
  foxDen.boot.secure = true;

  system.stateVersion = "25.05";

  imports = [ ../../../profiles/server.nix ];
  systemd.services."serial-getty@ttyS1".enable = true;
  boot.kernelParams = [
    "console=tty1"
    "console=ttyS1,115200n8"
  ];
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [
    "kvm-intel"
    "i40e"
  ];
  boot.extraModulePackages = [ ];
  powerManagement.cpuFreqGovernor = "performance";

  services.timesyncd.servers = [
    "ntp0.ovh.net"
  ];

  boot.swraid = {
    enable = true;
    mdadmConf = ''
      MAILADDR mdmon@doridian.net
      ARRAY /dev/md0 metadata=1.2 UUID=cd1e1189:475d9079:85633b66:6b8bb9f8
    '';
  };

  boot.initrd.luks.devices = {
    nixroot = {
      device = "/dev/md0";
      allowDiscards = true;
    };
  };

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=755" ];
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/nixroot";
    fsType = "xfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-id/ata-INTEL_SSDSC2BB480G7_BTDV718408J2480BGN-part1";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
      "nofail"
    ];
  };

  fileSystems."/boot2" = {
    device = "/dev/disk/by-id/ata-INTEL_SSDSC2BB480G7_PHDV732601C1480BGN-part1";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
      "nofail"
    ];
  };

  boot.lanzaboote.extraEfiSysMountPoints = [ "/boot2" ];

  foxDen.services = {
    watchdog.enable = true;
    netdata.enable = true;
    backupmgr.enable = config.lib.foxDen.sops.mkIfAvailable true;
  };
}
