{
  config,
  lib,
  pkgs,
  systemArch,
  ...
}:
let
  efiArch =
    if systemArch == "x86_64-linux" then "x64" else throw "Unsupported architecture ${systemArch}";

  ini = pkgs.formats.ini { };

  ukiCfg =
    profile:
    ini.generate "ukify.conf" {
      UKI = {
        Linux = "${profile}/kernel";
        Initrd = "${profile}/initrd";
        Cmdline = "__CMDLINE__";
        Stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${efiArch}.efi.stub";
        OSRelease = "@${config.system.build.etc}/etc/os-release";
      };
    };

  profileDir = "/nix/var/nix/profiles/system";
in
{
  options.foxDen.boot.uki = lib.mkEnableOption "Enable direct UKI boot";

  config.boot.loader = lib.mkIf config.foxDen.boot.uki {
    external = {
      enable = true;
      installHook = pkgs.writeShellScript "foxden-esp" (
        ''
          #!/usr/bin/env bash
          set -euo pipefail
          export PATH="$PATH:${pkgs.coreutils}/bin"

          TEMPDIR="$( mktemp -d)"
          cp "${ukiCfg profileDir}" "$TEMPDIR/ukify.conf"
          echo "init=$(cat ${profileDir}/boot.json | ${pkgs.jq}/bin/jq -r '."org.nixos.bootspec.v1".init') $(cat ${profileDir}/kernel-params)" > "$TEMPDIR/cmdline"
          ${pkgs.gnused}/bin/sed -i "s|__CMDLINE__|@$TEMPDIR/cmdline|" "$TEMPDIR/ukify.conf"
          ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
            --config="$TEMPDIR/ukify.conf" \
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
              espDir = "${esp}/EFI/TEST";
            in
            ''
              mkdir -p ${espDir}
              rm -rf ${espDir}_OLD ${espDir}_NEW
              cp -r "$TEMPDIR" ${espDir}_NEW
              rm -rf "$TEMPDIR"
              mv ${espDir} ${espDir}_OLD
              mv ${espDir}_NEW ${espDir}
            ''
          ) config.foxDen.boot.espMounts
        ))
      );
    };
  };
}
