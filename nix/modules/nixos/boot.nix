{
  lib,
  pkgs,
  config,
  lanzaboote,
  systemArch,
  ...
}:
{
  imports = [
    lanzaboote.nixosModules.lanzaboote
  ];

  options.foxDen.boot.secure = lib.mkEnableOption "Enable secure boot";

  config = {
    security = {
      audit.enable = false;
      apparmor.enable = true;
      lsm = [
        "lockdown"
        "integrity"
      ];
    };

    systemd.services.systemd-udev-settle.enable = false;

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
        "iommu=pt"
        "intel_iommu=on"
      ];
      # "audit=1" "audit_backlog_limit=256" "module.sig_enforce=1" "lockdown=integrity"

      loader.systemd-boot.enable = lib.mkForce (!config.foxDen.boot.secure);
      lanzaboote = lib.mkIf config.foxDen.boot.secure {
        enable = true;
        pkiBundle = "/etc/secureboot";
      };
    };

    environment.systemPackages = with pkgs; [
      sbctl
    ];

    environment.persistence."/nix/persist/system".directories = [
      {
        directory = "/etc/secureboot";
        mode = "u=rwx,g=rx,o=";
      }
    ];
  };
}
