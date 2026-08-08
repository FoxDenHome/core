#!/usr/bin/env bash
set -euo pipefail

curl -m 5 -fsL \
        http://router.foxden.network:9002/dkim.json \
        http://router-backup.foxden.network:9002/dkim.json \
        http://icefox.foxden.network:9002/dkim.json \
    | jq -s '.[0] * .[1] * .[2]'
