#!/usr/bin/env bash
set -euo pipefail

mkdir -p /tmp/run
ln -s /tmp/run /run
chown forgejo-runner:forgejo-runner /tmp/run
chmod 700 /tmp/run
