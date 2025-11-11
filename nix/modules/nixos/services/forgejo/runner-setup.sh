#!/usr/bin/env bash
set -euo pipefail

rundir="/run/user/$(id -u forgejo-runner)"
mkdir -p "/tmp${rundir}"
rm -rf /tmp/run /run
ln -s /run /tmp/run
chown forgejo-runner:forgejo-runner "$rundir"
chmod 700 "$rundir"
