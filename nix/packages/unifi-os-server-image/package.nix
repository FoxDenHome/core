{
  lib,
  pkgs,
  ...
}:
let
  # Based in parts on:
  # - https://discourse.nixos.org/t/unifi-os-server-on-nixos/76039
  # - https://www.unihosted.com/blog/running-unifi-os-server-in-docker

  # https://www.ui.com/download/releases/firmware
  version = "5.1.19";
  archConfig =
    {
      "aarch64-linux" = {
        src.url = "https://fw-download.ubnt.com/data/unifi-os-server/e027-linux-arm64-5.1.19-ebdd998e-306a-4880-af41-2bdc50e91e70.19-arm64";
        src.hash = "sha256:4e18c1f143cea3b364619406c35cf9d2123732bcdc500e41196e41196faefacf";
        firmwarePlatform = "linux-arm64";
      };
      "x86_64-linux" = {
        src.url = "https://fw-download.ubnt.com/data/unifi-os-server/b828-linux-x64-5.1.19-e38d0b0e-b462-403d-9861-f57f25772106.19-x64";
        src.hash = "sha256:014cc7da5c403ea4117f6d7fb4f3860036ad94f5bf58f5fcd029bec652416e66";
        firmwarePlatform = "linux-x64";
      };
    }
    .${pkgs.stdenv.system};

  imagePkg = pkgs.stdenvNoCC.mkDerivation {
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
      cat layer.json.orig
      CMD_ORIG="$(jq -r '.config.Cmd[0]' layer.json.orig)"
      jq -r ".config.Cmd[0] = \"/usr/local/sbin/init\" | .config.env |= . + [\"APP_VERSION=v${version}\",\"CMD_ORIG=$CMD_ORIG\",\"APP_MODEL=UOSSERVER\",\"PRODUCT_NAME=uosserver\",\"FIRMWARE_PLATFORM=${archConfig.firmwarePlatform}\"] | .rootfs.diff_ids |= . + [\"$LAYER_ID\"]" layer.json.orig > layer.json
      LAYER_CONFIG_ID="$(sha256sum layer.json | cut -d' ' -f1)"
      mv layer.json "$out/blobs/sha256/$LAYER_CONFIG_ID"

      # Step 3: Find and modify index config and put it in new hashed file
      mv "$out/blobs/sha256/$(jq -r '.manifests[0].digest' "$out/index.json" | cut -d':' -f2)" index_layer.json.orig
      jq -r ".layers |= . + [{\"mediaType\": \"application/vnd.docker.image.rootfs.diff.tar.gzip\", \"digest\": \"sha256:$BLOB_ID\", \"size\": $(stat -c%s "$out/blobs/sha256/$BLOB_ID")}] | .config.digest = \"sha256:$LAYER_CONFIG_ID\" | .config.size = $(stat -c%s "$out/blobs/sha256/$LAYER_CONFIG_ID")" index_layer.json.orig > index_layer.json
      INDEX_LAYER_CONFIG_ID="$(sha256sum index_layer.json | cut -d' ' -f1)"
      mv index_layer.json "$out/blobs/sha256/$INDEX_LAYER_CONFIG_ID"

      # Step 4: Modify manifest.json to point to new layer and new config
      mv "$out/manifest.json" manifest.json.orig
      jq -r ".[0].Layers |= . + [\"blobs/sha256/$BLOB_ID\"] | .[0].Config = \"blobs/sha256/$LAYER_CONFIG_ID\"" manifest.json.orig > "$out/manifest.json"

      # Step 5: Modify index.json to point to new layer and new config
      mv "$out/index.json" index.json.orig
      jq -r ".manifests[0].digest = \"sha256:$INDEX_LAYER_CONFIG_ID\" | .manifests[0].size = $(stat -c%s "$out/blobs/sha256/$INDEX_LAYER_CONFIG_ID")" index.json.orig > "$out/index.json"
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
    # ports =
    #   let
    #     portmapJson = lib.importJSON "${imagePkg}/portmap.json";
    #     portmapMerged = lib.mergeAttrsList (builtins.attrValues portmapJson);
    #   in
    #   lib.mapAttrsToList (hostPort: ctPort: "${hostPort}:${ctPort}") portmapMerged;
    volumes =
      let
        mountsJson = lib.importJSON "${imagePkg}/mounts.json";
        mountsMerged = lib.mergeAttrsList (builtins.attrValues mountsJson);
      in
      [
        "persistent:/persistent"
        "log:/var/log"
        "data:/data"
        "srv:/srv"
      ]
      ++ lib.mapAttrsToList (hostSpec: containerSpec: "${hostSpec}:${containerSpec}") mountsMerged;
  };
}
