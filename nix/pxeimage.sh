#!/usr/bin/env bash
set -euo pipefail

arch="${2-x86_64}"
OUTDIR="$1"
MACHINE="${arch}-netboot"

scriptdir="$(dirname "$(realpath "$0")")"
cd "$scriptdir"

buildsub() {
    nix build ".#nixosConfigurations.$MACHINE.config.system.build.$1" --no-link --print-out-paths
}

copy_out() {
    cp "$1" "${OUTDIR}/$2"
    chmod 644 "${OUTDIR}/$2"
}

copy_out_signed() {
	copy_out "$1" "$2"
    sbsign --key ~/Documents/foxden_pxe.key --cert ~/Documents/foxden_pxe.crt --output "${OUTDIR}/$2" "${OUTDIR}/$2"
}

copy_out_signed "$(buildsub uki)/nixos.efi" "uki-${arch}.efi"
