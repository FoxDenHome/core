#!/usr/bin/env bash
set -xeuo pipefail

BASEDIR="$1"

cd "${BASEDIR}/config/bluemap/packs/local"
zip -r ../local-resources.zip .
