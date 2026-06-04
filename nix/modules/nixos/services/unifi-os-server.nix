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
  imagePackage = pkgs.unifi-os-server-image;
in
{
  options.foxDen.services.unifi-os-server = foxDenLib.services.oci.mkOptions {
    name = "UniFi OS Server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        name = "unifi-os-server";
        inherit
          pkgs
          config
          svcConfig
          ;
        oci = {
          inherit (imagePackage.oci)
            image
            imageFile
            pull
            volumes
            ;
        };
        systemd.serviceConfig.ExecStartPre = [
          "+${(pkgs.writeShellScript "setup-cgroup.sh" ''
            cgroup="$(cat /proc/self/cgroup | ${pkgs.coreutils}/bin/cut -d: -f3 | head -1)"
            ${pkgs.coreutils}/bin/chown -R ${user.name}:${user.group} "/sys/fs/cgroup/$cgroup"
          '')}"
        ];
      }).config
      {
        foxDen.hosts.hosts.${svcConfig.host}.interfaces.default.nameOverride = "eth0";
      }
    ]
  );
}
