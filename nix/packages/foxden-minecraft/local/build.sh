#!/usr/bin/env bash
set -xeuo pipefail

BASEDIR="$(dirname "$0")"

cd "${BASEDIR}/config/bluemap/packs/local"
zip -r ../local-resources.zip .
