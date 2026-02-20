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
  efiArch =
    if systemArch == "x86_64-linux" then
      "x64"
    else if systemArch == "aarch64-linux" then
      "a64"
    else
      throw "Unsupported architecture ${systemArch}";

  ini = pkgs.formats.ini { };

  ukiCfg =
    profile:
    ini.generate "ukify.conf" {
      UKI = {
        Linux = "${profile}/kernel";
        Initrd = "${profile}/initrd";
        Cmdline = "@${profile}/kernel-params";
        Stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${efiArch}.efi.stub";
        OSRelease = "@${config.system.build.etc}/etc/os-release";
      };
    };
in
{
  foxDen.boot.override = true;

  boot.kernelParams = [ "cachebad=2" ];

  boot.loader = {
    systemd-boot.enable = lib.mkForce false;
    grub.enable = false;
    external = {
      enable = true;
      installHook = pkgs.writeShellScript "foxden-esp" (
        ''
          #!/usr/bin/env bash
          set -euo pipefail
          TEMPDIR="$( ${pkgs.coreutils}/bin/mktemp -d)"
          ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
            --config=${ukiCfg "/nix/var/nix/profiles/system"} \
            --output="$TEMPDIR/boot${efiArch}.efi"
        ''
        + (
          if config.foxDen.boot.secure then
            ''
              ${pkgs.sbsigntool}/bin/sbsign \
                          --key /etc/secureboot/keys/db/db.key \
                          --cert /etc/secureboot/keys/db/db.pem \
                          --output "$TEMPDIR/boot${efiArch}.efi" \
                          "$TEMPDIR/boot${efiArch}.efi"
            ''
          else
            "# SecureBoot is off"
        )
        + (lib.concatStringsSep "\n" (
          map (
            esp:
            let
              # TODO: We crash on finding the NixOS closure, so likely wrong initrd or cmdline
              espDir = "${esp}/EFI/BOOT_";
            in
            ''
              ${pkgs.coreutils}/bin/mkdir -p ${espDir}
              ${pkgs.coreutils}/bin/rm -rf ${espDir}_OLD ${espDir}_NEW
              ${pkgs.coreutils}/bin/cp -r "$TEMPDIR" ${espDir}_NEW
              ${pkgs.coreutils}/bin/mv ${espDir} ${espDir}_OLD
              ${pkgs.coreutils}/bin/mv ${espDir}_NEW ${espDir}
            ''
          ) espMounts
        ))
      );
    };
  };
}
