#!/usr/bin/env bash
set -euo pipefail

BACKUP_MIRROR="${1-}"

RDIR="tmpfs-scratch/"

mtik_backup() {
    RHOST="$1"
    RDOM="$2"
    RHOST_ABS="${RHOST}.${RDOM}"

    ssh "${RHOST_ABS}" "/system/backup/save dont-encrypt=yes name=${RDIR}${RHOST}-secret.backup"
    ssh "${RHOST_ABS}" "/export file=${RDIR}${RHOST}-secret.rsc show-sensitive terse verbose"

    sleep 1

    scp "${RHOST_ABS}:/${RDIR}${RHOST}-secret.backup" "${RHOST_ABS}:/${RDIR}${RHOST}-secret.rsc" ./
    if [ ! -z "${BACKUP_MIRROR}" ]
    then
        cp "${RHOST}-secret.backup" "${RHOST}-secret.rsc" "${BACKUP_MIRROR}"
    fi

    sleep 1

    ssh "${RHOST_ABS}" "/file/remove ${RDIR}${RHOST}-secret.backup"
    ssh "${RHOST_ABS}" "/file/remove ${RDIR}${RHOST}-secret.rsc"
}

mtik_backup router foxden.network
mtik_backup router-backup foxden.network
