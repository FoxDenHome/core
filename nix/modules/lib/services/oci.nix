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
        dependency = [ host.unit ];
      in
      {
        config = {
          virtualisation.oci-containers.containers."${ctName}" = nixpkgs.lib.mkMerge [
            {
              autoStart = nixpkgs.lib.mkDefault true;
              pull = nixpkgs.lib.mkDefault "always";
              networks = [ "host" ];

              volumes = [
                "/etc/localtime:/etc/localtime:ro"
                "/etc/locale.conf:/etc/locale.conf:ro"
              ];
              devices =
                if gpu && !config.hardware.nvidia-container-toolkit.enable then
                  config.foxDen.services.gpuDevices
                else
                  [ ];
              environment = {
                "TZ" = config.time.timeZone;
                "LANG" = config.i18n.defaultLocale;
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
            linger = false;
          };
          users.groups."${ctName}" = { };

          systemd.services."podman-${ctName}" = nixpkgs.lib.mkMerge [
            {
              requires = dependency;
              bindsTo = dependency;
              after = dependency;

              serviceConfig = {
                NetworkNamespacePath = host.namespacePath;
                Restart = nixpkgs.lib.mkDefault "always";
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
  mkOptions = inputs: foxDenLib.services.mkOptions inputs;
  mkNamed = mkNamed;
  make = inputs: mkNamed inputs.name inputs;

  nixosModule =
    { ... }:
    {
      environment.persistence."/nix/persist/oci" = {
        hideMounts = true;
        directories = [
          "/var/lib/foxden-oci"
        ];
      };
    };
}
