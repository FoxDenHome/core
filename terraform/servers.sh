#!/usr/bin/env bash
set -euo pipefail

rdir="$(dirname "$(realpath "$0")")"
nixdir="$(realpath "$rdir/../nix")"

cd "$rdir"
rm -f result
nix build "$nixdir#ipReverses.json"
jq '{json: . | tojson}' result
rm -f result
