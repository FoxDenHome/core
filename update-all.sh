#!/usr/bin/env bash
set -xeuo pipefail
cd "$(dirname "$0")"

cd nix && nix flake update && ./pin-cuda-nixpkgs.sh && cd ..
./nix/modules/nixos/services/games/factorio/enhance-mod-list.py
cd mikrotik && ./configure.py && cd ..
