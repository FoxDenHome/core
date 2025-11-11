#!/usr/bin/env bash
set -euo pipefail

rundir="/run/user/$(id -u forgejo-runner)"
mkdir -p "/tmp${rundir}"
ln -s /tmp/run /run
chown forgejo-runner:forgejo-runner "$rundir"
chmod 700 "$rundir"
