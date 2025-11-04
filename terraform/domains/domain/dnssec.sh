#!/usr/bin/env bash
set -euo pipefail

eval "$(jq -r '@sh "DOMAIN=\(.domain)"')"

fetch_dnskey_srv() {
    local domain="$1"
    local srv="$2"
    dig DNSKEY "$domain" "@$srv" | grep -v '^;' | sed 's/\s\s*/ /g' | grep -F ' DNSKEY 257 ' | awk '{print $1, 3600, $3, $4, $5, $6, $7, $8 $9}'
}

fetch_dnskey() {
    local domain="$1"
    echo ''
    fetch_dnskey_srv "$domain" pns41.cloudns.net || :
    fetch_dnskey_srv "$domain" router.foxden.network || :
    fetch_dnskey_srv "$domain" router-backup.foxden.network || :
}

fetch_dnskey "$DOMAIN" | jq -R '{dnskeys: [inputs] | tojson}'
