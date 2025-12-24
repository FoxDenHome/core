{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "carvera-controller";
  version = "1.0.0";
  src = pkgs.fetchzip {
    url = "https://github.com/MakeraInc/CarveraController/releases/download/v0.9.13/carvera-controller-0.9.13-x86_64-linux.tar.xz";
    hash = "sha256:4a3df262987f2ef49adbac74a7a45df0bb3ea64af56c6d0e38ee7ba8f5dd4d94";
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
