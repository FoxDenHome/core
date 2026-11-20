{
  lib,
  pkgs,
  config,
  systemArch,
  ...
}:
let
  mainEspMount = config.boot.loader.efi.efiSysMountPoint;
in
{
  options.foxDen.boot = {
    secure = lib.mkEnableOption "Enable secure boot";
    espMounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      defaultText = "[ config.boot.loader.efi.efiSysMountPoint ]";
      description = "List of mount points to copy the generated UKI to";
    };
  };

  config = {
    foxDen.boot.espMounts = [ mainEspMount ];

    security = {
      audit.enable = false;
      apparmor.enable = true;
      lsm = [
        "lockdown"
        "integrity"
      ];
    };
    services = {
      dbus.apparmor = "enabled";
    };

    boot = {
      initrd.availableKernelModules = [
        "sd_mod"
        "ahci"
        "xhci_pci"
        "ehci_pci"
        "nvme"
        "usbhid"
        "usb_storage"
      ];
      plymouth.enable = false;
      binfmt = {
        preferStaticEmulators = true;
        emulatedSystems = lib.lists.remove systemArch [
          "x86_64-linux"
          "aarch64-linux"
        ];
      };
      # Pinned to the 7.2 series of the zen kernel
      kernelPackages = lib.mkDefault (
        pkgs.linuxPackagesFor (
          pkgs.linux_zen.override {
            argsOverride = rec {
              version = "7.2.15";
              suffix = "zen1";
              modDirVersion = lib.versions.pad 3 "${version}-${suffix}";
              src = pkgs.fetchFromGitHub {
                owner = "zen-kernel";
                repo = "zen-kernel";
                rev = "v${version}-${suffix}";
                sha256 = "11w65vp17rhbilhlxrxzzp764is8ic66rrz9vvrn05cvl85rw755";
              };
            };
          }
        )
      );
      kernelParams = [
        "iommu=pt"
        "intel_iommu=on"
        "pci=realloc"
      ];

      loader.grub.enable = false;
      loader.systemd-boot.enable = lib.mkForce false;
    };

    environment.systemPackages = with pkgs; [
      sbctl
      sbsigntool
    ];

    environment.persistence."/nix/persist/system".directories = [
      {
        directory = "/etc/secureboot";
        mode = "u=rwx,g=rx,o=";
      }
    ];
  };
}
