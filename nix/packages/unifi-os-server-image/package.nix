{
  lib,
  pkgs,
  ...
}:
let
  version = "5.0.8";
  url = "https://fw-download.ubnt.com/data/unifi-os-server/c2e4-linux-x64-5.0.8-bcb62759-753a-4be2-8546-a6e0de63e59a.8-x64";
  sha256 = "db17656f222d371da5f96ed104e33503be16ca755817f126409b67d8009b1419";
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

    cp --link "$image_tar" "$out"
  '';

  meta = with lib; {
    description = "Extracted OCI image archive from the UniFi OS Server installer";
    homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
    license = licenses.unfreeRedistributableFirmware;
    platforms = platforms.linux;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
