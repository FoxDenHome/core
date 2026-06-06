#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

result="$(nix build "../../../..#sshHostDnsNames.json" --no-link --print-out-paths)"
HOSTS="$(jq -r '.[]' "$result")"

for host in $HOSTS; do
    if [ -f "records/$host" ]; then
        echo "records/$host exists, skipping"
        continue
    fi

    echo "records/$host missing, updating"
    ./update.sh "$host"
done
