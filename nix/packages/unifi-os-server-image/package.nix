{
  lib,
  pkgs,
  ...
}:
let
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

      volumes =
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
          "${mongoPreStartFix}:/etc/systemd/system/mongodb.service.d/prestart-fix.conf:ro"
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

      unzip "$src" image.tar mounts.json || true >/dev/null

      if [ ! -f image.tar ] || [ ! -f mounts.json ]; then
        echo "Could not find embedded image.tar or mounts.json in UniFi OS installer" >&2
        exit 1
      fi

      mkdir -p "$out"
      chmod 644 image.tar mounts.json
      cp mounts.json "$out/mounts.json"
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
