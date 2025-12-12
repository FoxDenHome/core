#!/usr/bin/env bash
set -xeuo pipefail

LATEST_VERSION_FILE=/server/minecraft-modpack.id
INSTALLED_VERSION_FILE="${SERVER_DIR}/minecraft-modpack.id"

run_update() {
  cd "${SERVER_DIR}"

  chmod -R 700 config/bluemap mods run.* libraries || true
  rm -rf config/bluemap mods run.* libraries

  find -type d -not -path './bluemap/*' -not -path './world/*' -exec chmod 700 {} \; || true
  find -type f -not -path './bluemap/*' -not -path './world/*' -exec chmod 600 {} \; || true
  cp -r /server/* ./
  find -type d -not -path './bluemap/*' -not -path './world/*' -exec chmod 700 {} \; || true
  find -type f -not -path './bluemap/*' -not -path './world/*' -exec chmod 600 {} \; || true
  chmod 700 ./*.sh

  exit 0
}

if [ ! -f "${INSTALLED_VERSION_FILE}" ]; then
  echo "No version file found, assuming fresh install"
  run_update
else
  INSTALLED_VERSION="$(cat "${INSTALLED_VERSION_FILE}")"
  LATEST_VERSION="$(cat "${LATEST_VERSION_FILE}")"
  if [ "${INSTALLED_VERSION}" != "${LATEST_VERSION}" ]; then
    echo "Version mismatch (current: ${INSTALLED_VERSION}, expected: ${LATEST_VERSION}), reinstalling"
    run_update
  else
    echo "Version matches (${INSTALLED_VERSION}), no reinstall needed"
    exit 0
  fi
fi
