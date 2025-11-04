#!/usr/bin/env bash
set -euo pipefail

DOMAIN="$1"

secure_zone() {
    local domain="$1"
    local router="$2"

    ssh "$router" "/container/shell pdns cmd=\"pdnsutil secure-zone $domain\""
}

secure_zone "$DOMAIN" router.foxden.network
secure_zone "$DOMAIN" router-backup.foxden.network
