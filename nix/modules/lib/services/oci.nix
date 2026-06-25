{ foxDenLib, nixpkgs, ... }:
let
  mkNamed = (
    ctName:
    {
      oci,
      systemd ? { },
      svcConfig,
      pkgs,
      config,
      gpu ? false,
      ...
    }:
    (
      let
        host = foxDenLib.hosts.getByName config svcConfig.host;
        hostName = foxDenLib.services.getFirstFQDN config svcConfig;
        dependency = [ host.unit ];
        forwardGpu = gpu && !config.hardware.nvidia-container-toolkit.enable;
      in
      {
        config = {
          virtualisation.oci-containers.containers."${ctName}" = nixpkgs.lib.mkMerge [
            {
              autoStart = nixpkgs.lib.mkDefault true;
              pull = nixpkgs.lib.mkDefault "always";
              networks = [ "host" ];
              hostname = nixpkgs.lib.mkDefault hostName;

              volumes = [
                "/etc/localtime:/etc/localtime:ro"
                "/etc/locale.conf:/etc/locale.conf:ro"
              ]
              ++ (
                if forwardGpu then
                  [

                    "/dev/dri/by-path:/dev/dri/by-path:ro"
                  ]
                  ++ (map (lib: "${lib}:${lib}:ro") config.foxDen.services.gpu.paths)
                else
                  [ ]
              );
              devices = if forwardGpu then config.foxDen.services.gpu.devices else [ ];
              environment = (if forwardGpu then config.foxDen.services.gpu.environment else { }) // {
                "TZ" = config.time.timeZone;
                "LANG" = config.i18n.defaultLocale;
                "LD_LIBRARY_PATH" = "";
                "LD_PRELOAD" = "";
              };

              podman = {
                user = ctName;
              };
            }
            oci
          ];

          users.users."${ctName}" = {
            isSystemUser = true;
            group = ctName;
            autoSubUidGidRange = true;
            home = "/var/lib/foxden-oci/${ctName}";
            createHome = true;
            linger = false; # This breaks container restarting in certain circumstances.
          };
          users.groups."${ctName}" = { };

          systemd.services."podman-${ctName}" = nixpkgs.lib.mkMerge [
            {
              requires = dependency;
              bindsTo = dependency;
              after = dependency;

              startLimitIntervalSec = nixpkgs.lib.mkForce 0;

              serviceConfig = {
                NetworkNamespacePath = host.namespacePath;

                Restart = nixpkgs.lib.mkDefault "always";
                RestartSec = nixpkgs.lib.mkForce "1s";
                RestartMaxDelaySec = nixpkgs.lib.mkForce "5m";
                RestartSteps = nixpkgs.lib.mkForce 10;

                BindReadOnlyPaths = [
                  "${host.resolvConf}:/etc/resolv.conf"
                ];
              };
            }
            systemd
          ];

          systemd.services."podman-${ctName}-prune" = {
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.podman}/bin/podman system prune --all --force --volumes --filter until=${builtins.toString (30 * 24)}h";
              Restart = "no";
            };
          };

          systemd.timers."podman-${ctName}-prune" = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "monthly";
              RandomizedDelaySec = "6h";
              Persistent = true;
            };
          };
        };
      }
    )
  );
in
{
  inherit (foxDenLib.services) mkOptions;
  mkNamed = mkNamed;
  make = inputs: mkNamed inputs.name inputs;

  nixosModule =
    { ... }:
    {
      # See above comment where linger is set to false
      foxDen.hideWarnings = [
        "^Podman container.*but lingering for this user is turned off.$"
      ];

      environment.persistence."/nix/persist/oci" = {
        hideMounts = true;
        directories = [
          "/var/lib/foxden-oci"
        ];
      };
    };
}
