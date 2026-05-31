{
  lib,
  pkgs,
  ...
}:
let
  # https://www.ui.com/download/releases/firmware
  version = "5.1.15";
  sources = {
    "aarch64-linux" = {
      url = "https://fw-download.ubnt.com/data/unifi-os-server/adc4-linux-arm64-5.1.15-53ab1f2c-4cd5-4a5f-b750-d1aa35679b4f.15-arm64";
      hash = "sha256:6cff0c1eedafbd82dddafb8324c2e21749814da586292a9554f63043b8c455f5";
    };
    "x86_64-linux" = {
      url = "https://fw-download.ubnt.com/data/unifi-os-server/24e0-linux-x64-5.1.15-926621de-c9d7-48cd-8921-a0ff3eebd3f4.15-x64";
      hash = "sha256:04c8e401eb34330fe99d94f35aa351e0e0e97895f0d9a4b459ff34fb50cad2bb";
    };
  };

  mongoMkdirs = pkgs.writeText "mongodb-mkdirs.conf" ''
    [Service]
    ExecStartPre=+/bin/mkdir -p /var/log/mongodb /var/lib/mongodb
    ExecStartPre=+/bin/chown mongodb:mongodb /var/log/mongodb /var/lib/mongodb
  '';

  nginxMkdirs = pkgs.writeText "nginx-mkdirs.conf" ''
    [Service]
    ExecStartPre=+/bin/mkdir -p /var/log/nginx
  '';

  unifiCoreMkdirs = pkgs.writeText "unifi-core-mkdirs.conf" ''
    [Service]
    ExecStartPre=+/bin/mkdir -p /data/unifi-core/config/http
  '';

  dbusStartFix = pkgs.writeText "dbus-start-fix.conf" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE busconfig SYSTEM "busconfig.dtd">
    <busconfig>
        <apparmor mode="disabled"/>
    </busconfig>
  '';

  imagePkg = pkgs.stdenvNoCC.mkDerivation {
    # reverse engineered via
    # https://www.unihosted.com/blog/running-unifi-os-server-in-docker
    pname = "unifi-os-server-image";
    inherit version;

    src = pkgs.fetchurl sources.${pkgs.stdenv.system};

    nativeBuildInputs = with pkgs; [
      coreutils
      unzip
      gnutar
    ];

    dontUnpack = true;

    passthru.oci = {
      environment = {
        APP_VERSION = "v${version}";
        APP_MODEL = "UOSSERVER";
        PRODUCT_NAME = "uosserver";
        FIRMWARE_PLATFORM = if pkgs.stdenv.hostPlatform.isAarch64 then "linux-arm64" else "linux-x64";
      };

      mkVolumes =
        rootDir:
        let
          mountsJson = lib.importJSON "${imagePkg}/mounts.json";
          mkAppVolumes =
            app: volumes: lib.mapAttrsToList (name: mount: "${rootDir}/${app}/${name}:${mount}") volumes;
        in
        [
          "${rootDir}/persistent:/persistent"
          "${rootDir}/log:/var/log"
          "${rootDir}/data:/data"
          "${rootDir}/srv:/srv"
          "${mongoMkdirs}:/etc/systemd/system/mongodb.service.d/mkdirs.conf:ro"
          "${nginxMkdirs}:/etc/systemd/system/nginx.service.d/mkdirs.conf:ro"
          "${unifiCoreMkdirs}:/etc/systemd/system/unifi-core.service.d/mkdirs.conf:ro"
          "${dbusStartFix}:/etc/dbus-1/system.d/start-fix.conf:ro"
          "${dbusStartFix}:/etc/dbus-1/session.d/start-fix.conf:ro"
        ]
        ++ (lib.naturalSort (
          lib.concatMap (app: mkAppVolumes app mountsJson.${app}) (lib.attrNames mountsJson)
        ));

      image =
        let
          imageManifest = lib.importJSON "${imagePkg}/manifest.json";
        in
        lib.replaceString "blobs/sha256/" "sha256:" (lib.lists.head imageManifest).Config;

      imageFile = imagePkg;
    };

    installPhase = ''
      set -euo pipefail

      unzip "$src" image.tar mounts.json portmap.json || true >/dev/null

      mkdir -p "$out"
      chmod 644 image.tar mounts.json portmap.json
      cp mounts.json portmap.json "$out"
      tar -xf image.tar -C "$out"
    '';

    meta = with lib; {
      description = "Extracted OCI image archive from the UniFi OS Server installer";
      homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
      license = licenses.unfreeRedistributableFirmware;
      platforms = platforms.linux;
      sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    };
  };
in
imagePkg
