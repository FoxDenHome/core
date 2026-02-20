{
  lib,
  pkgs,
  config,
  lanzaboote,
  systemArch,
  ...
}:
let
  mainEspMount = config.boot.loader.efi.efiSysMountPoint;
in
{
  imports = [
    lanzaboote.nixosModules.lanzaboote
  ];

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
      initrd.systemd.enable = true;

      plymouth = {
        enable = true;
        theme = lib.mkDefault "details";
      };

      binfmt.emulatedSystems = lib.lists.remove systemArch [
        "x86_64-linux"
        "aarch64-linux"
      ];

      kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
      kernelParams = [
        "iommu.passthrough=0"
        "intel_iommu=on"
      ];
      # "audit=1" "audit_backlog_limit=256" "module.sig_enforce=1" "lockdown=integrity"

      loader.grub.enable = false;
      loader.systemd-boot.enable = lib.mkForce (
        (!config.foxDen.boot.secure) && (!config.foxDen.boot.uki)
      );
      lanzaboote = lib.mkIf ((!config.foxDen.boot.uki) && config.foxDen.boot.secure) {
        enable = true;
        pkiBundle = "/etc/secureboot";
        extraEfiSysMountPoints = lib.lists.remove mainEspMount config.foxDen.boot.espMounts;
      };
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
