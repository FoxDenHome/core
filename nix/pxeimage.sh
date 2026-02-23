#!/usr/bin/env bash
set -euo pipefail

OUTDIR="$1"

cd "$(dirname "$(realpath "$0")")"

copy_out() {
    cp "$1" "${OUTDIR}/$2"
    chmod 644 "${OUTDIR}/$2"
}

copy_out_signed() {
    copy_out "$1" "$2"
    sbsign --key ~/Documents/foxden_pxe.key --cert ~/Documents/foxden_pxe.crt --output "${OUTDIR}/$2" "${OUTDIR}/$2"
}

build_arch() {
    copy_out_signed "$(nix build ".#nixosConfigurations.$1-netboot.config.system.build.uki" --no-link --print-out-paths)/nixos.efi" "uki-$1.efi"
    copy_out "$(nix build ".#nixosConfigurations.$1-netboot.config.system.build.netbootIpxeScript" --no-link --print-out-paths)/netboot.ipxe" "$1.ipxe"
    sed -i "s~bzImage~uki-$1.efi~g" "${OUTDIR}/$1.ipxe"
    sed -i "s~^initrd~#initrd~g" "${OUTDIR}/$1.ipxe"
    sed -i '2i imgfree' "${OUTDIR}/$1.ipxe"
    sed -i '3i set cmdline foxes=best' "${OUTDIR}/$1.ipxe"
}

build_arch x86_64
#build_arch aarch64
