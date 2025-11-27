#!/usr/bin/env bash
set -xeuo pipefail

LOCAL_DIR="$(realpath "$1")"
AUX_DIR="$(realpath "$2")"

bash "${LOCAL_DIR}/config/bluemap/local_pack/build.sh" "${AUX_DIR}"
