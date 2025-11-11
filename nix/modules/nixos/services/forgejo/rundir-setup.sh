#!/usr/bin/env bash
set -euo pipefail

rundir="/run/user/$(id -u forgejo-runner)"
mkdir -p "$rundir"
chown -h forgejo-runner:forgejo-runner "$rundir"
chmod -h 700 "$rundir"
