#!/usr/bin/env bash
set -xeuo pipefail
cd "$(dirname "$0")"

cd nix && nix flake update && cd ..
./nix/modules/nixos/services/games/factorio/enhance-mod-list.py
./mikrotik/files/tftp/update.sh
./nix/pxeimage.sh ~/nas/share/apps/pxe/nixos
