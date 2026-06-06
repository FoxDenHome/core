#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

result="$(nix build "../../../..#sshHostDnsNames.json" --no-link --print-out-paths)"
HOSTS="$(jq -r '.[]' "$result")"

for hostspec in $HOSTS; do
    host="${hostspec%@*}"
    primary="${hostspec#*@}"
    if [ "$host" != "$primary" ]; then
        echo "Host records/$host is an alias for $primary, symlinking"
        ln -sf "$primary" "records/$host"
        continue
    fi

    if [ -f "records/$host" ]; then
        echo "records/$host exists, skipping"
        continue
    fi

    echo "records/$host missing, updating"
    ./update.sh "$host"
done
