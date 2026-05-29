{
  lib,
  pkgs,
  ...
}:
let
  version = "5.1.15";
  url = "https://fw-download.ubnt.com/data/unifi-os-server/24e0-linux-x64-5.1.15-926621de-c9d7-48cd-8921-a0ff3eebd3f4.15-x64";
  sha256 = "04c8e401eb34330fe99d94f35aa351e0e0e97895f0d9a4b459ff34fb50cad2bb";
in
pkgs.stdenvNoCC.mkDerivation {
  # reverse engineered via
  # https://www.unihosted.com/blog/running-unifi-os-server-in-docker
  pname = "unifi-os-server-image";
  inherit version;

  src = pkgs.fetchurl {
    inherit url sha256;
  };

  nativeBuildInputs = with pkgs; [
    coreutils
    unzip
    gnutar
  ];

  dontUnpack = true;

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
}
