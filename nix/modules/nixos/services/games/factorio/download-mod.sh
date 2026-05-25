#!/bin/bash
set -euo pipefail

AUTH="$(cat "$1")"
NAME="$2"
URL="$3"

$wget -q -O "$NAME" "$URL?$AUTH"
