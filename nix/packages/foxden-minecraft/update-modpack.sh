#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/.local/share/PrismLauncher/instances/FoxDen Create 1.21 Server/minecraft/"

# modpack_foxden_create.zip is an export from PrismLauncher (FoxDen Create 1.21 Base) as a CurseForge ZIP
rm "$HOME/serverpack_foxden_create.zip"
zip -r "$HOME/serverpack_foxden_create.zip" config configureddefaults coremods defaultconfigs mods resourcepacks server-resource-packs

TARGET=islandfox.foxden.network
addfile() {
  local fpath="$1"
  local fname="$(basename "$fpath")"
  sha256sum "$fpath"
  rsync "$fpath" "$TARGET:$fname"
  ssh "$TARGET" -- nix-store --add-fixed sha256 "'$fname'" >/dev/null
}

addfile "$HOME/serverpack_foxden_create.zip"
addfile "$HOME/modpack_foxden_create.zip"
