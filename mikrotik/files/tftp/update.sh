#!/usr/bin/env bash
set -xeuo pipefail

scriptdir="$(dirname "$(realpath "$0")")"
nixdir="${scriptdir}/../../../nix"
cd "$scriptdir"

ipxedir="$(nix build "$nixdir#nixosConfigurations.islandfox.pkgs.foxden-ipxe" --no-link --print-out-paths)"
wimboot_dir="$(nix build "$nixdir#nixosConfigurations.islandfox.pkgs.wimboot" --no-link --print-out-paths)"

copy_and_sign() {
	cp "$1" "$2"
	chmod 644 "$2"
	sbsign --key ~/Documents/foxden_pxe.key --cert ~/Documents/foxden_pxe.crt --output "$2" "$2"
}

copy_arch() {
	copy_and_sign "$ipxedir/$1/ipxe.efi" "ipxe-$1.efi"
	copy_and_sign "$ipxedir/$1/snp.efi" "ipxe-$1-snponly.efi"
	if [ -f "$ipxedir/$1/wimboot.efi" ]; then
		copy_and_sign "$ipxedir/$1/wimboot.efi" "wimboot-$1.efi"
	fi
}

copy_arch x86_64
copy_arch aarch64
