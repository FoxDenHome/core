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
          User = "forgejo-runner";
          Group = "forgejo-runner";
          ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner";
          ExecReload = "${pkgs.coreutils}/bin/kill -s HUP $MAINPID";
          BindReadOnlyPaths = [
            "/usr/bin/env"
            "${config.sops.secrets."forgejo-runner-registration".path}:/registration.json"
          ];
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
