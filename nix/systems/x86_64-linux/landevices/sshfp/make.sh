#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

ssh-keyscan -D "$1" | grep -v '^;' | cut -d' ' -f4- > "records/$1"
