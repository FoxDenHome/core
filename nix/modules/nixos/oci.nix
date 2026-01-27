{ ... }:
{
  environment.persistence."/nix/persist/oci" = {
    hideMounts = true;
    directories = [
      "/var/lib/containers"
    ];
  };

  virtualisation = {
    oci-containers.backend = "podman";
    containers = {
      enable = true;
      containersConf.settings = {
        engine = {
          cgroup_manager = "cgroupfs";
        };
      };
    };
    podman.autoPrune = {
      enable = true;
      flags = [ "--all" ];
    };
  };
}
