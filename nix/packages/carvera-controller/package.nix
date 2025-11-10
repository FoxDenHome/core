{ lib, pkgs, ... }:
let
  lib-rewrites = pkgs.stdenv.mkDerivation {
    name = "carvera-controller-lib-rewrite";
    version = "1.0.0";
    srcs = [ ];

    unpackPhase = "true";

    installPhase = ''
      mkdir -p $out/lib
      ln -s ${pkgs.libffi}/lib/libffi.so $out/lib/libffi.so.7
      ln -s ${pkgs.mpdecimal}/lib/libmpdec.so $out/lib/libmpdec.so.2
      ln -s ${lib.getLib pkgs.openssl}/lib/libcrypto.so $out/lib/libcrypto.so.1.1
      ln -s ${lib.getLib pkgs.openssl}/lib/libssl.so $out/lib/libssl.so.1.1
    '';
  };
in
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
    openssl
    lib-rewrites
    (lib.getLib stdenv.cc.cc)
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
