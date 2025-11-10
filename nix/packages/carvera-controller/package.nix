{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "carvera-controller";
  version = "1.0.0";
  srcs = [
    (pkgs.fetchzip {
      url = "https://github.com/MakeraInc/CarveraController/releases/download/v0.9.11/carvera-controller-0.9.11-x86_64-linux.tar.xz";
      hash = "sha256-YAROnzEaPIWbS3gdL1kr0Goj5+gAraxetZBIaOpqSnA=";
    })
  ];

  nativeBuildInputs = [
    pkgs.autoPatchelfHook
  ];

  buildInputs = with pkgs; [
    expat
    xorg.libX11
    xorg.libXrender
    libGL
    libgcc
    mpdecimal
    readline
    zlib
    xz
    bzip2
    libffi
    (lib.getLib openssl)
    (lib.getLib stdenv.cc.cc)
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libcrypto.so.1.1"
    "libssl.so.1.1"
    "libmpdec.so.2"
    "libffi.so.7"
  ];

  unpackPhase = ''
    for srcFile in $srcs; do
      if [ -d "$srcFile" ]; then
        cp -r "$srcFile" ./files
      else
        echo '# TODO'
      fi
    done
  '';

  installPhase = ''
    mkdir -p $out
    cp -r ./files/* $out/
  '';
}
