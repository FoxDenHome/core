#!/usr/bin/env bash
set -euo pipefail
OUTDIR="$1"
MACHINE="${2-amd64-netboot}"

scriptdir="$(dirname "$(realpath "$0")")"
cd "$scriptdir"

buildsub() {
    nix build ".#nixosConfigurations.$MACHINE.config.system.build.$1" --no-link --print-out-paths
}

cp "$(buildsub netbootIpxeScript)/netboot.ipxe" "${OUTDIR}/netboot.ipxe"
cp "$(buildsub netbootRamdisk)/initrd" "${OUTDIR}/initrd"
cp "$(buildsub kernel)/bzImage" "${OUTDIR}/bzImage"

chmod 644 "${OUTDIR}"/*
