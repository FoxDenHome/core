{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  mkDir = (
    dir: {
      directory = dir;
      user = "forgejo-runner";
      group = "forgejo-runner";
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.forgejo-runner;
in
{
  options.foxDen.services.forgejo-runner = services.mkOptions {
    svcName = "forgejo-runner";
    name = "Forgejo runner server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "forgejo-runner";
        inherit svcConfig pkgs config;
      }).config
      {
        users.users.forgejo-runner = {
          isSystemUser = true;
          group = "forgejo-runner";
          description = "Forgejo runner user";
          autoSubUidGidRange = true;
          home = "/var/lib/forgejo-runner";
        };
        users.groups.forgejo-runner = { };

        sops.secrets."forgejo-runner-registration" = {
          owner = "forgejo-runner";
          group = "forgejo-runner";
          mode = "0400";
        };

        systemd.tmpfiles.rules = [
          "d /run/user-forgejo-runner 0700 forgejo-runner forgejo-runner"
        ];

        systemd.services.forgejo-runner =
          let
            packages = with pkgs; [
              bash
              coreutils
              git
              gnugrep
              gnused
              gnutar
              go
              nixfmt-rfc-style
              nixfmt-tree
              nodejs_24
              podman
              python312
              python313
              python314
              shadow
              systemd
              uv
            ];
          in
          {
            confinement.packages = packages;
            path = [ "/run/wrappers" ] ++ packages;

            serviceConfig = {
              ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /config.yml";
              ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
              ExecStartPre = [
                "+${./runner-setup.sh}"
                "-${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner"
                "${pkgs.coreutils}/bin/cp --update=all /registration.json /var/lib/forgejo-runner/.runner"
                "${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner"
              ];
              BindPaths = [
                "/run/user-forgejo-runner:/run/user"
              ];
              Environment = [
                "UV_PYTHON_DOWNLOADS=never"
              ];
              BindReadOnlyPaths = [
                "-/lib"
                "-/lib64"
                "/run/wrappers/bin/newuidmap"
                "/run/wrappers/bin/newgidmap"
                "/etc/containers/containers.conf"
                "/etc/containers/policy.json"
                "/etc/containers/registries.conf"
                "/etc/containers/storage.conf"
                "/usr/bin/env"
                "${./runner-config.yml}:/config.yml"
                "${config.sops.secrets."forgejo-runner-registration".path}:/registration.json"
              ];
              PrivatePIDs = true;
              PrivateTmp = true;
              PrivateUsers = false; # Podman rootless need subuid/subgid
              ProtectKernelTunables = false; # Otherwise podman can't remount /proc
              User = "forgejo-runner";
              Group = "forgejo-runner";
              WorkingDirectory = "/var/lib/forgejo-runner";
              StateDirectory = "forgejo-runner";
            };

            wantedBy = [ "multi-user.target" ];
          };

        environment.persistence."/nix/persist/forgejo" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/forgejo-runner")
          ];
        };
      }
    ]
  );
}
