{ foxDenLib, pkgs, lib, config, ... }:
let
  services = foxDenLib.services;

  mkDir = (dir: {
    directory = dir;
    user = "forgejo-runner";
    group = "forgejo-runner";
    mode = "u=rwx,g=,o=";
  });

  svcConfig = config.foxDen.services.forgejo-runner;
in
{
  options.foxDen.services.forgejo-runner = services.mkOptions { svcName = "forgejo-runner"; name = "Forgejo runner server"; };

  config = lib.mkIf svcConfig.enable (lib.mkMerge [
    (services.make {
      name = "forgejo-runner";
      inherit svcConfig pkgs config;
    }).config
    {
      users.users.forgejo-runner = {
        isSystemUser = true;
        group = "forgejo-runner";
        description = "Forgejo runner user";
        linger = true;
        home = "/var/lib/forgejo-runner";
      };
      users.groups.forgejo-runner = { };

      sops.secrets."forgejo-runner-registration" = {
        owner = "forgejo-runner";
        group = "forgejo-runner";
        mode = "0400";
      };

      systemd.services.forgejo-runner = {
        confinement.packages = with pkgs; [
          podman
        ];
        path = with pkgs; [
          podman
        ];

        serviceConfig = {
          ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon --config /config.yml";
          ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
          ExecStartPre = [
            "-${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner"
            "${pkgs.coreutils}/bin/cp -f /registration.json /var/lib/forgejo-runner/.runner"
            "${pkgs.coreutils}/bin/chmod 600 /var/lib/forgejo-runner/.runner"
          ];
          BindReadOnlyPaths = [
            "/usr/bin/env"
            "${./runner-config.yml}:/config.yml"
            "${config.sops.secrets."forgejo-runner-registration".path}:/registration.json"
          ];
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
  ]);
}
