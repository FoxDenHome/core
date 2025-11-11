#!/usr/bin/env bash
set -euo pipefail


rm -rf /run/user
mkdir /tmp/run-user
ln -s /tmp/run-user /run/user

rundir="/run/user/$(id -u forgejo-runner)"
mkdir -p "$rundir"
chown forgejo-runner:forgejo-runner "$rundir"
chmod 700 "$rundir"
