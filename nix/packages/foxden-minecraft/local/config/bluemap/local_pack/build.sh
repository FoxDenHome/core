#!/usr/bin/env bash
set -xeuo pipefail

BASEDIR="$(dirname "$0")"

OUTDIR="${1}/config/bluemap/packs"
mkdir -p "${OUTDIR}"
OUTDIR_ABS="$(realpath "${OUTDIR}")"

cd "${BASEDIR}"
zip -r "${OUTDIR_ABS}/local-resources.zip" .
