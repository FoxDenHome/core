{
  lib,
  pkgs,
  ...
}:
let
  # https://www.ui.com/download/releases/firmware
  version = "5.1.15";
  archConfig =
    {
      "aarch64-linux" = {
        src.url = "https://fw-download.ubnt.com/data/unifi-os-server/adc4-linux-arm64-5.1.15-53ab1f2c-4cd5-4a5f-b750-d1aa35679b4f.15-arm64";
        src.hash = "sha256:6cff0c1eedafbd82dddafb8324c2e21749814da586292a9554f63043b8c455f5";
        firmwarePlatform = "linux-arm64";
      };
      "x86_64-linux" = {
        src.url = "https://fw-download.ubnt.com/data/unifi-os-server/24e0-linux-x64-5.1.15-926621de-c9d7-48cd-8921-a0ff3eebd3f4.15-x64";
        src.hash = "sha256:04c8e401eb34330fe99d94f35aa351e0e0e97895f0d9a4b459ff34fb50cad2bb";
        firmwarePlatform = "linux-x64";
      };
    }
    .${pkgs.stdenv.system};

  imagePkg = pkgs.stdenvNoCC.mkDerivation {
    # reverse engineered via
    # https://www.unihosted.com/blog/running-unifi-os-server-in-docker
    pname = "unifi-os-server-image";
    inherit version;

    src = pkgs.fetchurl archConfig.src;

    nativeBuildInputs = with pkgs; [
      coreutils
      unzip
      gnutar
      jq
    ];

    dontUnpack = true;

    installPhase = ''
      set -euo pipefail

      unzip "$src" image.tar mounts.json portmap.json || true >/dev/null
      chmod 644 image.tar mounts.json portmap.json

      mkdir -p "$out"
      cp mounts.json portmap.json "$out"
      tar -xf image.tar -C "$out"

      # Step 1: Create custom overlay layer .tar.gz and store in the right place
      tar -cf overlay.tar -C "${./rootfs}" .
      LAYER_ID="sha256:$(sha256sum overlay.tar | cut -d' ' -f1)"
      gzip -9 overlay.tar
      BLOB_ID="$(sha256sum overlay.tar.gz | cut -d' ' -f1)"
      mv overlay.tar.gz "$out/blobs/sha256/$BLOB_ID"

      # Step 2: Modify actual layer config and put it in new hashed file as well as ENV vars
      mv "$out/$(jq -r '.[0].Config' "$out/manifest.json")" layer.json.orig
      jq ".config.env |= . + [\"APP_VERSION=v${version}\",\"APP_MODEL=UOSSERVER\",\"PRODUCT_NAME=uosserver\",\"FIRMWARE_PLATFORM=${archConfig.firmwarePlatform}\"] | .rootfs.diff_ids |= . + [\"$LAYER_ID\"]" layer.json.orig > layer.json
      LAYER_CONFIG_ID="$(sha256sum layer.json | cut -d' ' -f1)"
      mv layer.json "$out/blobs/sha256/$LAYER_CONFIG_ID"

      # Step 3: Find and modify index config and put it in new hashed file
      mv "$out/blobs/sha256/$(jq -r '.manifests[0].digest' "$out/index.json" | cut -d':' -f2)" index_layer.json.orig
      jq ".layers |= . + [{\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\", \"digest\": \"sha256:$BLOB_ID\", \"size\": $(stat -c%s "$out/blobs/sha256/$BLOB_ID")}] | .config.digest = \"sha256:$LAYER_CONFIG_ID\" | .config.size = $(stat -c%s "$out/blobs/sha256/$LAYER_CONFIG_ID")" index_layer.json.orig > index_layer.json
      INDEX_LAYER_CONFIG_ID="$(sha256sum index_layer.json | cut -d' ' -f1)"
      mv index_layer.json "$out/blobs/sha256/$INDEX_LAYER_CONFIG_ID"

      # Step 4: Modify manifest.json to point to new layer and new config
      mv "$out/manifest.json" manifest.json.orig
      jq ".[0].Layers |= . + [\"blobs/sha256/$BLOB_ID\"] | .[0].Config = \"blobs/sha256/$LAYER_CONFIG_ID\"" manifest.json.orig > "$out/manifest.json"

      # Step 5: Modify index.json to point to new layer and new config
      mv "$out/index.json" index.json.orig
      jq ".manifests[0].digest = \"sha256:$INDEX_LAYER_CONFIG_ID\" | .manifests[0].size = $(stat -c%s "$out/blobs/sha256/$INDEX_LAYER_CONFIG_ID")" index.json.orig > "$out/index.json"
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
// {
  oci = {
    image =
      let
        imageManifest = lib.importJSON "${imagePkg}/manifest.json";
      in
      lib.replaceString "blobs/sha256/" "sha256:" (lib.lists.head imageManifest).Config;
    imageFile = imagePkg;
    pull = "never";
    extraOptions = [
      "--systemd=always"
    ];
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
      ]
      ++ (lib.naturalSort (
        lib.concatMap (app: mkAppVolumes app mountsJson.${app}) (lib.attrNames mountsJson)
      ));
  };
}
