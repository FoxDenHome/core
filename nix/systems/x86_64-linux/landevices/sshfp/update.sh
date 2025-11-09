#!/usr/bin/env bash
set -euo pipefail
set -x
cd "$(dirname "$0")"
(ssh-keyscan -4 -D "$1" || ssh-keyscan -6 -D "$1") > "tmp-$1.txt"
cat "tmp-$1.txt" | grep -v '^;' | cut -d' ' -f4- > "records/$1"
rm -f "tmp-$1.txt"
