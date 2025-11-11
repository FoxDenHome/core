#!/usr/bin/env bash
set -euo pipefail

rm -rf /run/user
ln -s /tmp/run-user /run/user
