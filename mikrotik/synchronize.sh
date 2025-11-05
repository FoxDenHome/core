#!/usr/bin/env bash
set -euo pipefail

# TODO: Do SFTP inside of refresh.py entirely and remove this script

transfer_files() {
    cd files
    scp -r . "$1:/"
    cd ..
}

uv run refresh.py

transfer_files router.foxden.network
ssh router.foxden.network '/file/add name=container-restart-all'

transfer_files router-backup.foxden.network
ssh router-backup.foxden.network '/file/add name=container-restart-all'
