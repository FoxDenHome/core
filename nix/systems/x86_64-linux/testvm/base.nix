{ ... }:
{
  foxDen.sops.available = false;
  foxDen.boot.secure = false;

  system.stateVersion = "25.05";

  documentation = {
    man.enable = false;
    info.enable = false;
    doc.enable = false;
    nixos.enable = false;
  };

  hardware.enableRedistributableFirmware = true;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio"
  ];
  boot.extraModulePackages = [ ];
  boot.kernelParams = [ "net.ifnames=0" ];

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=755" ];
  };

  fileSystems."/nix" = {
    device = "/dev/vda2";
    fsType = "xfs";
  };

  fileSystems."/boot" = {
    device = "/dev/vda1";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
      "nofail"
    ];
  };
}
