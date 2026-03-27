{
  lib,
  pkgs,
  ...
}:
let
  version = "5.0.6";
  url = "https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64";
  sha256 = "20fa164791938b2ec9d5680c118753c46a36eaa3369cef94d5cef8da9468df9e";
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
    binwalk
    coreutils
    findutils
  ];

  dontUnpack = true;

  installPhase = ''
    set -euo pipefail

    work="$PWD/work"
    mkdir -p "$work"
    cp "$src" "$work/unifi-os-installer"
    chmod u+w "$work/unifi-os-installer"
    cd "$work"

    binwalk -e ./unifi-os-installer >/dev/null

    image_tar="$(find . -type f -name image.tar | head -n1)"
    if [ -z "$image_tar" ]; then
      echo "Could not find embedded image.tar in UniFi OS installer" >&2
      exit 1
    fi

    mkdir -p "$out"
    tar -xf "$image_tar" -C "$out"
  '';

  meta = with lib; {
    description = "Extracted OCI image archive from the UniFi OS Server installer";
    homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
    license = licenses.unfreeRedistributableFirmware;
    platforms = platforms.linux;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
