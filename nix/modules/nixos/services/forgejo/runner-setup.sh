#!/usr/bin/env bash
set -euo pipefail

rundir="/run/user/$(id -u forgejo-runner)"
mkdir -p "$rundir"
chown forgejo-runner:forgejo-runner "$rundir"
chmod 700 "$rundir"
