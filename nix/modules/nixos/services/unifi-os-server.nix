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

  # MongoDB needs writable log and data dirs; + runs as root regardless of User=
  mongoPreStartFix = pkgs.writeText "mongodb-prestart-fix.conf" ''
    [Service]
    ExecStartPre=+/bin/chown mongodb:mongodb /var/log/mongodb /var/lib/mongodb"
  '';

  dbusStartFix = pkgs.writeText "dbus-start-fix.conf" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE busconfig SYSTEM "busconfig.dtd">
    <busconfig>
        <apparmor mode="disabled"/>
    </busconfig>
  '';

  name = "unifi-os-server";

  imagePackage = pkgs.unifi-os-server-image;
  imageManifest = lib.importJSON "${imagePackage}/manifest.json";

  eSA = lib.strings.escapeShellArg;
  allVolumes =
    let
      mountsJson = lib.importJSON "${imagePackage}/mounts.json";
      mkAppVolumes =
        app: volumes: lib.mapAttrsToList (name: mount: "${stateDir}/${app}/${name}:${mount}") volumes;
    in
    [
      "${stateDir}/persistent:/persistent"
      "${stateDir}/log:/var/log"
      "${stateDir}/data:/data"
      "${stateDir}/srv:/srv"
    ]
    ++ (lib.concatMap (app: mkAppVolumes app mountsJson.${app}) (lib.attrNames mountsJson));
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
          image = lib.replaceString "blobs/sha256/" "sha256:" (lib.lists.head imageManifest).Config;
          imageFile = imagePackage;
          pull = "never";
          volumes =
            let
            in
            [
              "${mongoPreStartFix}:/etc/systemd/system/mongodb.service.d/prestart-fix.conf:ro"
              "${dbusStartFix}:/etc/dbus-1/system.d/start-fix.conf:ro"
              "${dbusStartFix}:/etc/dbus-1/session.d/start-fix.conf:ro"
            ]
            ++ allVolumes;
          environment = {
            APP_VERSION = "v${imagePackage.version}";
            APP_MODEL = "UOSSERVER";
            PRODUCT_NAME = "uosserver";
            FIRMWARE_PLATFORM = if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64";
          };
          extraOptions = [
            "--systemd=always"
          ];
        };
        systemd = {
          preStart = lib.mkAfter ''
            ${pkgs.coreutils}/bin/mkdir -p ${
              lib.concatStringsSep " " (map (vol: eSA (lib.head (lib.splitString ":" vol))) allVolumes)
            } ${stateDir}/{data/unifi-core/config/http,log/nginx,log/mongodb}

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
