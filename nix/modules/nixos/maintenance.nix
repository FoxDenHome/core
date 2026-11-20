{
  config,
  lib,
  pkgs,
  ...
}:
let
  updateScript = ''
    set -xeuo pipefail
    nix flake update --flake 'git+https://git.foxden.network/FoxDen/core?dir=nix' || :
    exec nixos-rebuild switch --flake "git+https://git.foxden.network/FoxDen/core?dir=nix#$(hostname)"
  '';

  pruneAllScript = ''
    set -xeuo pipefail
    nix-collect-garbage --delete-old
    /run/current-system/bin/switch-to-configuration boot
  '';

  cryptenrollScript = ''
    set -xeuo pipefail
    enroll_disk() {
      systemd-cryptenroll --wipe-slot tpm2 --tpm2-device auto --tpm2-pcrs '0:sha256+7:sha256+14:sha256' "$1"
    }

    manual_disk="''${1-}"
    if [ ! -z "$manual_disk" ]; then
      enroll_disk "$manual_disk"
      exit 0
    fi
  ''
  + (builtins.concatStringsSep "\n" (
    map (dev: "enroll_disk ${dev.device}") (lib.attrsets.attrValues config.boot.initrd.luks.devices)
  ))
  + "\n";
in
{
  config = {
    nix = {
      daemonCPUSchedPolicy = "idle";
      daemonIOSchedClass = "idle";
      gc = {
        automatic = true;
        dates = [ "*-*-01 05:00:00" ];
        randomizedDelaySec = "4h";
      };
      optimise = {
        automatic = true;
        dates = [ "*-*-04 05:00:00" ];
        randomizedDelaySec = "4h";
      };
      settings = {
        keep-derivations = true;
        keep-outputs = true;
        auto-optimise-store = true;
      };
    };

    environment.etc."foxden/cryptenroll.sh".source =
      pkgs.writeShellScript "cryptenroll.sh" cryptenrollScript;
    environment.etc."foxden/nixos/prune-all.sh".source =
      pkgs.writeShellScript "nixos-prune-all.sh" pruneAllScript;
    environment.etc."foxden/nixos/update.sh".source = pkgs.writeShellScript "nixos-update.sh" ''
      set -euo pipefail
      # No set -x: trace lines would interleave with the journal output below.

      # Print the nixos-update journal entries selected by the journalctl
      # arguments in "$@" until a run ends. Exits non-zero if the run failed.
      # The selection must not include the end of an earlier run, so it is
      # never a wall clock --since (second granularity lets a run that ended
      # in the same second match).
      follow_run() {
        journalctl --no-hostname --follow --no-tail "$@" |
          awk '/: nixos-update.service: Deactivated successfully/ { print; exit; }; /: nixos-update.service: Failed with result/ { print; exit 1; }; { print; }'
      }

      # A start on an already-running unit is a no-op, which would just attach to
      # an update that may predate the newest commit. Wait for it to finish first,
      # showing its output meanwhile.
      while true; do
        # One call, so the state and invocation belong to the same run.
        state=""
        invocation=""
        while IFS='=' read -r key value; do
          case "$key" in
            ActiveState) state="$value" ;;
            InvocationID) invocation="$value" ;;
          esac
        done < <(systemctl show --property=ActiveState,InvocationID nixos-update)
        case "$state" in
          active | activating | deactivating | reloading | refreshing)
            echo "nixos-update is $state, showing its output until it finishes..."
            if [ -n "$invocation" ]; then
              # Only this run's entries: its own output (_SYSTEMD_INVOCATION_ID)
              # and PID 1's messages about it (INVOCATION_ID).
              follow_run "_SYSTEMD_INVOCATION_ID=$invocation" + "INVOCATION_ID=$invocation" || :
              echo "Previous nixos-update finished, starting a new one..."
            else
              sleep 1
            fi
            ;;
          *)
            break
            ;;
        esac
      done
      # Everything logged after this cursor belongs to the run started below.
      cursor="$(journalctl --quiet --lines=0 --show-cursor | sed -n 's/^-- cursor: //p')"
      systemctl --no-block start nixos-update
      follow_run --unit nixos-update --after-cursor="$cursor"
    '';

    users.groups.maintainers = { };

    security.polkit.extraConfig = ''
      const MAINTENANCE_SERVICES = {
        "nixos-update.service": true,
      };
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
          MAINTENANCE_SERVICES[action.lookup("unit")] &&
          subject.isInGroup("maintainers"))
          {
            return polkit.Result.YES;
          }
      });
    '';

    systemd.services.nixos-update = {
      description = "FoxDen NixOS update service";
      after = [ "network.target" ];
      conflicts = [ "foxden-auto-prune.service" ];

      path = [ "/run/current-system/sw" ];
      script = updateScript;
      serviceConfig = {
        Type = "simple";
        Restart = "no";
        LimitNOFILE = 524288;
      };
    };
  };
}
