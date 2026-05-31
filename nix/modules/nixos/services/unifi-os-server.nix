{
  config,
  lib,
  pkgs,
  foxDenLib,
  ...
}:
let
  user = config.users.users.unifi-os-server;
  svcConfig = config.foxDen.services.unifi-os-server;
  stateDir = user.home;
  name = "unifi-os-server";
  imagePackage = pkgs.unifi-os-server-image;
in
{
  # Based on:
  # - https://discourse.nixos.org/t/unifi-os-server-on-nixos/76039
  # - https://www.unihosted.com/blog/running-unifi-os-server-in-docker
  options.foxDen.services.unifi-os-server = foxDenLib.services.oci.mkOptions {
    svcName = name;
    name = "UniFi OS Server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        inherit
          pkgs
          config
          svcConfig
          name
          ;
        oci = {
          inherit (imagePackage.oci)
            image
            imageFile
            environment
            ;
          volumes = imagePackage.oci.mkVolumes stateDir;

          pull = "never";
          extraOptions = [
            "--systemd=always"
          ];
        };
        systemd = {
          preStart = lib.mkAfter ''
            # The Java UniFi controller requires exactly UUID v5 (SHA-1 name-based).
            # Generate a stable v5 UUID derived from the machine-id.
            uuid_file="${stateDir}/data/uos_uuid"
            if [ ! -f "$uuid_file" ]; then
              ${pkgs.util-linux}/bin/uuidgen -s -n @dns -N "$(${pkgs.coreutils}/bin/cat /etc/machine-id)" > "$uuid_file"
            fi
          '';
          serviceConfig = {
            ExecStartPre = [
              "+${(pkgs.writeShellScript "setup-cgroup.sh" ''
                cgroup="$(cat /proc/self/cgroup | ${pkgs.coreutils}/bin/cut -d: -f3 | head -1)"
                ${pkgs.coreutils}/bin/chown -R ${user.name}:${user.group} "/sys/fs/cgroup/$cgroup"
              '')}"
            ];
          };
        };
      }).config
      {
        foxDen.hosts.hosts.${svcConfig.host}.interfaces.default.nameOverride = "eth0";
      }
    ]
  );
}
