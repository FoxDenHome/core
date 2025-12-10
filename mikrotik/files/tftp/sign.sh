#!/usr/bin/env bash
set -xeuo pipefail

sign() {
	sbsign --key ~/Documents/foxden_pxe.key --cert ~/Documents/foxden_pxe.crt --output "$1" "$1"
}
for bin in *.efi; do
	sign "$bin"
done
