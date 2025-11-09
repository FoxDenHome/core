{ ... }:
{
  # These are set when you reinstall the system
  # Change them to "false" for first boot, before secrets exist
  # then, once stuff is done, set them to true
  foxDen.sops.available = false;
  foxDen.boot.secure = false;

  system.stateVersion = "25.05";

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "nvme" "mpt3sas" "usbhid" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

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
    options = [ "fmask=0022" "dmask=0022" ];
  };
}
