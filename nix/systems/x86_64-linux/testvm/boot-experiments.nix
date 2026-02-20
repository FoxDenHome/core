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
  efiArch =  if systemArch == "x86_64-linux" then "x64" else if  systemArch == "aarch64-linux" then "a64" else throw "Unsupported architecture ${systemArch}";

  ini = pkgs.formats.ini {};

  ukiCfg =
    profile:
    ini.generate "ukify.conf" {
      UKI = {
        Linux = "${profile}/kernel";
        Initrd = "${profile}/initrd";
        Cmdline = "@${profile}/kernel-params";
        Stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${efiArch}.efi.stub";
        OSRelease = "@${config.system.build.etc}/etc/os-release";
      } // (if config.foxDen.boot.secure then {
        SecureBootSigningTool = "sbsign";
        SecureBootPrivateKey = "/etc/secureboot/keys/db/db.key";
        SecureBootCertificate = "/etc/secureboot/keys/db/db.pem";
      } else {});
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
              --output=${esp}/EFI_/BOOT/boot${efiArch}.efi
          '') espMounts
        )
      );
    };
  };
}
