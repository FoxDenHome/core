#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
SYNC_SCRIPT="$1"

export MIRROR_TARGET="/data"
export LOCAL_DIR="${MIRROR_TARGET}/.dori-local"
export LASTPULL_BASE="${LOCAL_DIR}/lastpull"

mkdir -p "${LOCAL_DIR}"

if [ -z "${MIRROR_SOURCE_HTTPS-}" ]; then
	export LASTUPDATE_URL=''
else
	export LASTUPDATE_URL="${MIRROR_SOURCE_HTTPS}/lastupdate"
fi

echo "[EXEC] Upstream mirror: ${MIRROR_SOURCE_RSYNC} / ${MIRROR_SOURCE_HTTPS-}"

echo "[EXEC] Running ${SYNC_SCRIPT}"
ecode=0
bash "${SYNC_SCRIPT}" || ecode=$?
echo "[EXEC] Sync completed with code: ${ecode}"

date '+%s' > "${LASTPULL_BASE}"
if [ "${ecode}" -eq 0 ]; then
    cp -f "${LASTPULL_BASE}" "${LASTPULL_BASE}-success"
else
    cp -f "${LASTPULL_BASE}" "${LASTPULL_BASE}-error"
fi
