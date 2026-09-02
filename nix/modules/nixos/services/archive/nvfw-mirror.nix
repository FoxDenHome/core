{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.nvfw-mirror;
in
{
  options.foxDen.services.nvfw-mirror = services.mkOptions {
    name = "nVidia networking FW mirror";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "nvfw-mirror";
        inherit svcConfig pkgs config;
      }).config
      {
        users.users.nvfw-mirror = {
          isSystemUser = true;
          description = "nvfw-mirror service user";
          group = "nvfw-mirror";
        };
        users.groups.nvfw-mirror = { };

        systemd.services.nvfw-mirror = {
          serviceConfig = {
            ExecStart = [
              "${pkgs.nvfw-mirror}/bin/nvfw-mirror --root /var/lib/nvfw-mirror"
            ];

            User = "nvfw-mirror";
            Group = "nvfw-mirror";
            StateDirectory = "nvfw-mirror";
          };
        };

        systemd.timers.nvfw-mirror = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "daily";
            RandomizedDelaySec = "45m";
          };
        };

        environment.persistence."/nix/persist/nvfw-mirror" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/nvfw-mirror";
              user = "nvfw-mirror";
              group = "nvfw-mirror";
              mode = "u=rwx,g=rx,o=rx";
            }
          ];
        };
      }
    ]
  );
}
