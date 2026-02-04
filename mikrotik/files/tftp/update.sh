#!/usr/bin/env bash
set -xeuo pipefail

scriptdir="$(dirname "$(realpath "$0")")"
nixdir="${scriptdir}/../../../nix"
cd "$scriptdir"

sign() {
	local file="$1"
	sbsign --key ~/Documents/foxden_pxe.key --cert ~/Documents/foxden_pxe.crt --output "$file" "$file"
}

cpsign() {
	local src="$1"
	local dest="$2"
	cp "$src" "$dest"
	sign "$dest"
}

makearch() {
	local arch="$1"
	local machine="$2"
	local ipxedir="$(nix build "$nixdir#nixosConfigurations.$machine.pkgs.foxden-ipxe" --no-link --print-out-paths)"
	cpsign "$ipxedir/ipxe.efi" "ipxe-$arch.efi"
	cpsign "$ipxedir/snp.efi" "ipxe-$arch-snponly.efi"
}

makearch x86_64 islandfox
