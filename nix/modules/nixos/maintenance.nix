{
  config,
  lib,
  pkgs,
  ...
}:
let
  updateScript = ''
    if [ -f /nix/persist/update.disable ]; then
      echo "Auto-update disabled via /nix/persist/update.disable, skipping"
      exit 1
    fi
    set -xeuo pipefail
    nix flake update --flake 'git+https://git.foxden.network/FoxDen/core?dir=nix' || :
    nixos-rebuild switch --flake "git+https://git.foxden.network/FoxDen/core?dir=nix#$(hostname)" || :
    nix-collect-garbage --delete-older-than 30d
    /run/current-system/bin/switch-to-configuration boot
  '';

  pruneAllScript = ''
    set -xeuo pipefail
    nix-collect-garbage --delete-old
    /run/current-system/bin/switch-to-configuration boot
  '';

  cryptenrollScript = ''
    #!/usr/bin/env bash
    set -xeuo pipefail
    enroll_disk() {
      systemd-cryptenroll --wipe-slot tpm2 --tpm2-device auto --tpm2-pcrs '0:sha256+7:sha256+14:sha256' "$1"
    }
  ''
  + (builtins.concatStringsSep "\n" (
    map (dev: "enroll_disk ${dev.device}") (lib.attrsets.attrValues config.boot.initrd.luks.devices)
  ))
  + "\n";
in
{
  environment.etc."foxden/cryptenroll.sh".source =
    pkgs.writeShellScript "cryptenroll.sh" cryptenrollScript;
  environment.etc."foxden/nixos-prune.sh".source =
    pkgs.writeShellScript "nixos-prune-all.sh" pruneAllScript;

  systemd.services.foxden-auto-update = {
    description = "FoxDen NixOS auto-update service";
    after = [ "network.target" ];
    conflicts = [ "foxden-auto-prune.service" ];

    path = [ "/run/current-system/sw" ];
    script = updateScript;
    serviceConfig = {
      Type = "simple";
      Restart = "no";
    };
  };

  systemd.timers.foxden-auto-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 4:00:00";
      RandomizedDelaySec = "1h";
    };
  };
}
