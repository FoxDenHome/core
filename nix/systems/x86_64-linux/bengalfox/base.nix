{ config, pkgs, ... }:
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
    "console=ttyS1,115200n8"
    "console=tty1"
  ];
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ehci_pci"
    "nvme"
    "mpt3sas"
    "usbhid"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [
    "kvm-intel"
    "rdma_cm"
    "mlx5_core"
    "mlx5_en"
  ];
  boot.extraModulePackages = [ ];
  foxDen.nvidia.enable = true;
  powerManagement.cpuFreqGovernor = "ondemand";

  environment.systemPackages = with pkgs; [
    mstflint
  ];

  boot.swraid = {
    enable = true;
    mdadmConf = ''
      MAILADDR mdmon@doridian.net
      ARRAY /dev/md0 metadata=1.2 UUID=a84487b7:a5d11a87:32de3997:dacc0654
      ARRAY /dev/md1 metadata=1.2 UUID=115c644c:fcb4a527:5d784e0c:9c379b03
    '';
  };

  boot.initrd.luks.devices = {
    nixroot = {
      device = "/dev/md0";
      allowDiscards = true;
    };
    zssd = {
      device = "/dev/md1";
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

  fileSystems."/mnt/zssd" = {
    device = "/dev/mapper/zssd";
    fsType = "xfs";
    options = [ "nofail" ];
  };

  foxDen.services = {
    watchdog.enable = true;
    superfan.enable = true;
    netdata.enable = true;
    apcupsd.enable = config.lib.foxDen.sops.mkIfAvailable true;
  };
}
