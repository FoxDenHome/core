#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "DOMAIN=\(.domain)"')"

fetch_dnskey_srv() {
    local domain="$1"
    local srv="$2"
    local port="$3"
    dig DNSKEY "$domain" -p "$port" "@$srv" | grep -v '^;' | sed 's/\s\s*/ /g' | grep -F ' DNSKEY 257 ' | awk '{print $1, 3600, $3, $4, $5, $6, $7, $8 $9}'
}

fetch_dnskey() {
    local domain="$1"
    echo ''
    fetch_dnskey_srv "$domain" pns41.cloudns.net 53 || :
    fetch_dnskey_srv "$domain" router.foxden.network 530 || :
    fetch_dnskey_srv "$domain" router-backup.foxden.network 530 || :
}

fetch_dnskey "$DOMAIN" | jq -R '{dnskeys: [inputs] | tojson}'
