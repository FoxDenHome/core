#!/usr/bin/env bash
set -euo pipefail

BACKUP_MIRROR="${1-}"

RDIR="tmpfs-scratch/"

mkdir -p ./backup

mtik_backup() {
    RHOST="$1"
    RDOM="$2"
    RHOST_ABS="${RHOST}.${RDOM}"

    ssh "${RHOST_ABS}" "/system/backup/save dont-encrypt=yes name=${RDIR}${RHOST}.backup"
    ssh "${RHOST_ABS}" "/export file=${RDIR}${RHOST}.rsc show-sensitive terse verbose"

    sleep 1

    scp "${RHOST_ABS}:/${RDIR}${RHOST}.backup" "${RHOST_ABS}:/${RDIR}${RHOST}.rsc" ./backup
    if [ ! -z "${BACKUP_MIRROR}" ]
    then
        cp "backup/${RHOST}.backup" "backup/${RHOST}.rsc" "${BACKUP_MIRROR}"
    fi

    sleep 1

    ssh "${RHOST_ABS}" "/file/remove ${RDIR}${RHOST}.backup"
    ssh "${RHOST_ABS}" "/file/remove ${RDIR}${RHOST}.rsc"
}

mtik_backup router foxden.network
mtik_backup router-backup foxden.network
mtik_backup redfox doridian.net
