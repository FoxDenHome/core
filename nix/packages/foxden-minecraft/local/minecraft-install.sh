#!/usr/bin/env bash
set -xeuo pipefail

LATEST_ID_FILE=/server/minecraft-modpack.id
INSTALLED_ID_FILE="${SERVER_DIR}/minecraft-modpack.id"

LATEST_LOCK="$0"
INSTALLED_LOCK_FILE="${SERVER_DIR}/minecraft-modpack.lock"

superdel() {
  chmod -R 700 "$@" || true
  rm -rf "$@"
}

run_update() {
  cd "${SERVER_DIR}"

  superdel config/bluemap config/paxi/datapacks config/paxi/local_pack bluemap/web/index.html bluemap/web/assets bluemap/web/lang configureddefaults coremods defaultconfigs mods resourcepacks server-resource-packs

  find -mindepth 1 -maxdepth 1 -not -path './bluemap' -not -path './world' -exec chmod -R u+rwX,go-rwx {} + || true
  cp -r /server/* ./
  find -mindepth 1 -maxdepth 1 -not -path './bluemap' -not -path './world' -exec chmod -R u+rwX,go-rwx {} + || true

  echo "${LATEST_LOCK}" > "${INSTALLED_LOCK_FILE}"

  exit 0
}

if [ ! -f "${INSTALLED_LOCK_FILE}" ]; then
  echo "No lock file found, assuming fresh install"
  run_update
else
  INSTALLED_LOCK="$(cat "${INSTALLED_LOCK_FILE}")"
  if [ "${INSTALLED_LOCK}" != "${LATEST_LOCK}" ]; then
    echo "Lock mismatch (current: ${INSTALLED_LOCK}, expected: ${LATEST_LOCK}), upgrading"
    run_update
  else
    echo "Lock matches (${INSTALLED_LOCK}), no upgrade needed"
    exit 0
  fi
fi
