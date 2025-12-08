{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "carvera-controller";
  version = "1.0.0";
  src = pkgs.fetchzip {
    url = "https://github.com/MakeraInc/CarveraController/releases/download/v0.9.11/carvera-controller-0.9.11-x86_64-linux.tar.xz";
    hash = "sha256:bb766175e585e1f8c996cb1d3e6a7a192132e48c4ac60f27f3ebff4816e79281";
  };

  nativeBuildInputs = [
    pkgs.autoPatchelfHook
  ];

  buildInputs = with pkgs; [
    (lib.getLib mtdev)
    (lib.getLib openssl)
    (lib.getLib stdenv.cc.cc)
    bzip2
    expat
    libffi_3_3
    libgcc
    libGL
    mpdecimal
    readline
    xorg.libX11
    xorg.libXrender
    xz
    zlib
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libcrypto.so.1.1"
    "libssl.so.1.1"
    "libmpdec.so.2"
  ];

  runtimeDependencies = with pkgs; [
    (lib.getLib mtdev)
  ];

  appendRunpaths =
    with pkgs;
    lib.makeLibraryPath [
      mtdev
    ];

  unpackPhase = ''
    cp -r "$src" ./files
  '';

  installPhase = ''
    cp -r ./files $out
  '';
}
