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

  ukiCfg = ini.generate "ukify.conf" {
    UKI = {
      Linux = "__PROFILE__/kernel";
      Initrd = "__PROFILE__/initrd";
      Cmdline = "__CMDLINE__";
      Stub = "${pkgs.systemd}/lib/systemd/boot/efi/linux${efiArch}.efi.stub";
      OSRelease = "@${config.system.build.etc}/etc/os-release";
    };
  }; # boot${efiArch}.efi
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

          TEMPDIR="$(mktemp -d)"
          FIXED_PROFILES=/nix/var/nix/profiles/system-*-link
          MAIN_PROFILE=/nix/var/nix/profiles/system

          makeuki() {
            local name="$1"
            local profile="$2"
            if [ -f "$TEMPDIR/$name.efi" ]; then
              return 0
            fi
            cp -f "${ukiCfg}" "$TEMPDIR/ukify.conf"
            echo "init=$(cat "$profile/boot.json" | ${pkgs.jq}/bin/jq -r '."org.nixos.bootspec.v1".init') $(cat "$profile/kernel-params")" > "$TEMPDIR/cmdline"
            ${pkgs.gnused}/bin/sed -i "s|__CMDLINE__|@$TEMPDIR/cmdline|" "$TEMPDIR/ukify.conf"
            ${pkgs.gnused}/bin/sed -i "s|__PROFILE__|$profile|" "$TEMPDIR/ukify.conf"
            ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
              --config="$TEMPDIR/ukify.conf" \
              --output="$TEMPDIR/$name.efi"
        ''
        + (
          if config.foxDen.boot.secure then
            ''
              ${pkgs.sbsigntool}/bin/sbsign \
                          --key /etc/secureboot/keys/db/db.key \
                          --cert /etc/secureboot/keys/db/db.pem \
                          --output "$TEMPDIR/$name.efi" \
                          "$TEMPDIR/$name.efi"
            ''
          else
            "# SecureBoot is off"
        )
        + ''
          }

          copyuki() {
            local name="$1"
            makeuki "$@"
            cp -f "$TEMPDIR/$name.efi" "$name.efi"
          }

          espkeep() {
            local name="$1"
            cat "$TEMPDIR/espfiles.remove" | ${pkgs.gnugrep}/bin/grep -v "^$name$" > "$TEMPDIR/espfiles.remove.new" || return 0
            mv "$TEMPDIR/espfiles.remove.new" "$TEMPDIR/espfiles.remove"
          }

          buildesp() {
            local esp="$1/EFI/TEST"
            echo "Building UKI for $esp with $1"
            mkdir -p "$esp"
            ls "$esp" > "$TEMPDIR/espfiles.remove"
            pushd "$esp"
            for profile in $FIXED_PROFILES; do
              local name="nixos-$(basename "$profile" | cut -d- -f2)"
              espkeep "$name.efi"
              if [ -f "$name.efi" ]; then
                continue
              fi
              copyuki "$name" "$profile"
            done
            rm -f "bootold.efi"
            mv "boot${efiArch}.efi" "bootold.efi" || true
            copyuki "boot${efiArch}" "$MAIN_PROFILE"
            espkeep "boot${efiArch}.efi"
            espkeep bootold.efi
            cat "$TEMPDIR/espfiles.remove" | ${pkgs.findutils}/bin/xargs -r rm -fv
            popd
          };
        ''
        + (lib.concatStringsSep "\n" (map (esp: "buildesp ${esp}") config.foxDen.boot.espMounts))
        + ''
          ; rm -rf "$TEMPDIR"
        ''
      );
    };
  };
}
