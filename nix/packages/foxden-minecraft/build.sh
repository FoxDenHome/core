#!/usr/bin/env bash
set -xeuo pipefail

SUBDIR='config/bluemap/packs'

BASEDIR="$1"
OUTDIR="$(realpath "$2")"

cd "${BASEDIR}/${SUBDIR}/../local_pack"
mkdir -p "${OUTDIR}/${SUBDIR}"
zip -r "${OUTDIR}/${SUBDIR}/local-resources.zip" .
