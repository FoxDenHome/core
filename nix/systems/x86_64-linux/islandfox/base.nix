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
    "mlx5_core"
    "mlx5_en"
    "r8169"
    "rdma_cm"
  ];
  boot.extraModulePackages = [ ];
  foxDen.amdgpu.enable = true;

  services.hardware.bolt.enable = true;
  environment.systemPackages = [ config.services.hardware.bolt.package ];
  environment.persistence."/nix/persist/system".directories = [
    {
      directory = "/var/lib/boltd";
      mode = "u=rwx,g=rx,o=rx";
    }
  ];

  powerManagement.cpuFreqGovernor = "performance";

  boot.swraid = {
    enable = true;
    mdadmConf = ''
      MAILADDR mdmon@doridian.net
      ARRAY /dev/md0 metadata=1.2 UUID=136007e2:4e9703e7:7ea3b9c8:fd1b6cff
    '';
  };

  boot.extraModprobeConfig = ''
    blacklist bluetooth
    blacklist btintel
    blacklist btrtl
    blacklist btmtk
    blacklist btbcm
    blacklist btusb
    blacklist mt7921e

    alias pci:v000014C3d00000616sv000014C3sd0000C616bc02sc80i00 vfio-pci
    options vfio-pci ids=14c3:0616
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
