#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

rm -f result
nix build "../../../..#sshHostDnsNames.json"
RECORDS="$(jq -r '.[]' result)"
rm -f result
for record in $RECORDS; do
    if [ -f "records/$record" ]; then
        echo "records/$record exists, skipping"    
    else
        echo "records/$record missing, updating"
        ./update.sh "$record"
    fi
done
