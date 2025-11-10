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
