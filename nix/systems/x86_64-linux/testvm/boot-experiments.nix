{
  config,
  lib,
  pkgs,
  ...
}:
let
  espMounts = [
    "/boot"
  ];

  ukiCfg =
    profile:
    pkgs.formats.ini.generate "ukify.conf" {
      UKI = {
        Linux = "${profile}/kernel";
        Initrd = "${profile}/initrd";
        Cmdline = "@${profile}/kernel-params";
        Stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${pkgs.stdenv.hostPlatform}.efi.stub";
        Uname = config.boot.kernelPackages.kernel.modDirVersion;
        OSRelease = "@${config.system.build.etc}/etc/os-release";
        # This is needed for cross compiling.
        EFIArch = pkgs.stdenv.hostPlatform;
      };
    };
in
{
  foxDen.boot.override = true;

  boot.loader = {
    systemd-boot.enable = lib.mkForce false;
    grub.enable = false;
    external = {
      enable = true;
      installHook = pkgs.writeShellScript "foxden-esp" (
        lib.concatStringsSep "\n" (
          map (esp: ''
            ${pkgs.coreutils}/bin/mkdir -p ${esp}/EFI_/BOOT
            cd ${esp}/EFI_/BOOT
            ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
              --config=${ukiCfg "/nix/var/nix/profiles/system"} \
              --output=BOOTX64.EFI
          '') espMounts
        )
      );
    };
  };
}
