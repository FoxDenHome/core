#!/usr/bin/env bash
set -euo pipefail

rdir="$(dirname "$(realpath "$0")")"
nixdir="$(realpath "$rdir/../nix")"

cd "$rdir"
result="$(nix build "$nixdir#dns.json" --no-link --print-out-paths)"
jq '{json: . | tojson}' "$result"
