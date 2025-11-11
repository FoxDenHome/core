{ foxDenLib, nixpkgs, ... }:
let
    mkNamed = (ctName: { oci, systemd ? {}, svcConfig, pkgs, config, ... }: (let
      host = foxDenLib.hosts.getByName config svcConfig.host;
      dependency = [ host.unit ];
    in {
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
        };
        users.groups."${ctName}" = {};

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
      };
    }));
in
{
  mkOptions = inputs: foxDenLib.services.mkOptions inputs;
  mkNamed = mkNamed;
  make = inputs: mkNamed inputs.name inputs;

  nixosModule = { ... }:
  {
    config.environment.persistence."/nix/persist/oci" = {
      hideMounts = true;
      directories = [
        "/var/lib/containers"
        "/var/lib/foxden-oci"
      ];
    };

    config.virtualisation.oci-containers.backend = "podman";

    config.virtualisation.containers.containersConf.settings = {
      cgroup_manager = "cgroupfs";
    };

    config.virtualisation.podman.autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
  };
}
