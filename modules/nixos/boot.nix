{ lib, pkgs, config, lanzaboote, ... }:
{
  imports = [
    lanzaboote.nixosModules.lanzaboote
  ];

  options.foxDen.boot.secure = lib.mkEnableOption "Enable secure boot";

  config = {
    security.audit.enable = false;
    security.apparmor.enable = true;

    security.lsm = [ "lockdown" "integrity" ];

    boot = {
      initrd.systemd.enable = true;

      kernelPackages = pkgs.linuxPackages_latest;
      kernelParams = ["module.sig_enforce=1" "lockdown=integrity" "iommu=pt" "intel_iommu=on" "amd_iommu=on"];
      # "audit=1" "audit_backlog_limit=256"

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
      { directory = "/etc/secureboot"; mode = "u=rwx,g=rx,o="; }
    ];
  };
}
