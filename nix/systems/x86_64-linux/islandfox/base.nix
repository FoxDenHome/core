{ config, ... }:
{
  # These are set when you reinstall the system
  # Change them to "false" for first boot, before secrets exist
  # then, once stuff is done, set them to true
  foxDen.sops.available = true;
  foxDen.boot.secure = true;

  system.stateVersion = "25.05";

  imports = [ ../../../profiles/server.nix ];
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [
    "kvm-amd"
    "r8169"
  ];
  boot.extraModulePackages = [ ];

  services.xserver.videoDrivers = [ "amdgpu" ];
  hardware.graphics.enable = true;

  boot.swraid = {
    enable = true;
    mdadmConf = ''
      MAILADDR mdmon@doridian.net
      ARRAY /dev/md0 metadata=1.2 UUID=660f8703:f7ec5be9:b586b082:ce74a589
    '';
  };

  boot.extraModprobeConfig = ''
    blacklist bluetooth
    blacklist btintel
    blacklist btrtl
    blacklist btmtk
    blacklist btbcm
    blacklist btusb

    alias pci:v00008086d00002723sv00008086sd00000080bc02sc80i00 vfio-pci
    options vfio-pci ids=8086:0080
  '';

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
    device = "/dev/nvme0n1p1";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
      "nofail"
    ];
  };

  fileSystems."/boot2" = {
    device = "/dev/nvme1n1p1";
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
    apcupsd.enable = config.lib.foxDen.sops.mkIfAvailable true;
  };
}
