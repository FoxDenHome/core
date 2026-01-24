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

  superdel config/bluemap config/paxi/datapacks mods

  # Use this if we update Forge/Minecraft versions maybe, otherwise pointless
  #INSTALLED_ID="$(cat "${INSTALLED_ID_FILE}" || echo none)"
  #LATEST_ID="$(cat "${LATEST_ID_FILE}")"
  #if [ "${INSTALLED_ID}" != "${LATEST_ID}" ]; then
  #  echo "ID mismatch (current: ${INSTALLED_ID}, expected: ${LATEST_ID}), reinstalling"
  #  superdel run.* libraries
  #fi

  find -type d -not -path './bluemap/*' -not -path './world/*' -exec chmod 700 {} \; || true
  find -type f -not -path './bluemap/*' -not -path './world/*' -exec chmod 600 {} \; || true
  cp -r /server/* ./
  find -type d -not -path './bluemap/*' -not -path './world/*' -exec chmod 700 {} \; || true
  find -type f -not -path './bluemap/*' -not -path './world/*' -exec chmod 600 {} \; || true
  chmod 700 ./*.sh

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
