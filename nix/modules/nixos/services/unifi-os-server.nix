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

  # Fix missing directories that services expect but don't create on first run.
  ucorePreStartFix = pkgs.writeText "unifi-core-prestart-fix.conf" ''
    [Service]
    ExecStartPre=-/bin/mkdir -p /data/unifi-core/config/http
    ExecStartPre=-/bin/mkdir -p /var/log/nginx
  '';

  # MongoDB needs writable log and data dirs; + runs as root regardless of User=
  mongoPreStartFix = pkgs.writeText "mongodb-prestart-fix.conf" ''
    [Service]
    ExecStartPre=+/bin/bash -c "mkdir -p /var/log/mongodb && chown mongodb:mongodb /var/log/mongodb /var/lib/mongodb"
  '';

  dbusStartFix = pkgs.writeText "dbus-start-fix.conf" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE busconfig SYSTEM "busconfig.dtd">
    <busconfig>
        <apparmor mode="disabled"/>
    </busconfig>
  '';

  name = "unifi-os-server";

  ifaceFirstV4 =
    iface:
    foxDenLib.util.removeIPCidr (
      lib.findFirst (ip: foxDenLib.util.isIPv4 ip && foxDenLib.util.isPrivateIP ip) "" iface.addresses
    );
  primaryIPv4 = ifaceFirstV4 config.foxDen.hosts.hosts.${svcConfig.host}.interfaces.default;

  imageManifest = lib.importJSON "${pkgs.unifi-os-server-image}/manifest.json";
in
{
  # Based on:
  # - https://discourse.nixos.org/t/unifi-os-server-on-nixos/76039
  # - https://www.unihosted.com/blog/running-unifi-os-server-in-docker
  options.foxDen.services.unifi-os-server = {
  }
  // (foxDenLib.services.oci.mkOptions {
    svcName = name;
    name = "UniFi OS Server";
  });

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
          image = (lib.lists.head (lib.lists.head imageManifest).RepoTags);
          imageFile = pkgs.unifi-os-server-image;
          pull = "never";
          volumes = [
            "${stateDir}/persistent:/persistent"
            "${stateDir}/log:/var/log"
            "${stateDir}/data:/data"
            "${stateDir}/srv:/srv"
            "${stateDir}/unifi:/var/lib/unifi"
            "${stateDir}/mongodb:/var/lib/mongodb"
            "${ucorePreStartFix}:/etc/systemd/system/unifi-core.service.d/prestart-fix.conf:ro"
            "${mongoPreStartFix}:/etc/systemd/system/mongodb.service.d/prestart-fix.conf:ro"
            "${dbusStartFix}:/etc/dbus-1/system.d/start-fix.conf:ro"
            "${dbusStartFix}:/etc/dbus-1/session.d/start-fix.conf:ro"
          ];
          environment = {
            UOS_SYSTEM_IP = primaryIPv4;
            UOS_SERVER_VERSION = pkgs.unifi-os-server-image.version;
            FIRMWARE_PLATFORM = if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64";
          };
          privileged = true;
          extraOptions = [
            "--systemd=always"
            "--security-opt=seccomp=unconfined"
            "--security-opt=apparmor=unconfined"
            "--add-host=host.docker.internal:${primaryIPv4}"
          ];
        };
        systemd = {
          preStart = lib.mkAfter ''
            ${pkgs.coreutils}/bin/mkdir -p ${stateDir}/{persistent,log,data,srv,unifi,mongodb}

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
