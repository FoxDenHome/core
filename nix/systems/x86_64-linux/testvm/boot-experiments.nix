{
  config,
  lib,
  pkgs,
  systemArch,
  ...
}:
let
  espMounts = [
    "/boot"
  ];

  ini = pkgs.formats.ini {};

  ukiCfg =
    profile:
    ini.generate "ukify.conf" {
      UKI = {
        Linux = "${profile}/kernel";
        Initrd = "${profile}/initrd";
        Cmdline = "@${profile}/kernel-params";
        Stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${systemArch}.efi.stub";
        OSRelease = "@${config.system.build.etc}/etc/os-release";
      };
    };
in
{
  foxDen.boot.override = true;

  boot.kernelParams = [ "cachebad=1" ];

  boot.loader = {
    systemd-boot.enable = lib.mkForce false;
    grub.enable = false;
    external = {
      enable = true;
      installHook = pkgs.writeShellScript "foxden-esp" (
        lib.concatStringsSep "\n" (
          map (esp: ''
            set -ex
            ${pkgs.coreutils}/bin/mkdir -p ${esp}/EFI_/BOOT
            ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
              --config=${ukiCfg "/nix/var/nix/profiles/system"} \
              --output=${esp}/EFI_/BOOT/BOOTX64.EFI
          '') espMounts
        )
      );
    };
  };
}
