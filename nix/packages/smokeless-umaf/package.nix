{
  pkgs,
  ...
}:
pkgs.stdenvNoCC.mkDerivation {
  name = "smokeless-umaf";
  version = "1.0.0";
  src = ./efi;

  unpackPhase = "true";
  installPhase = ''
    mkdir -p $out/usr/share/smokeless-umaf
    cp -r $src/* $out/usr/share/smokeless-umaf/
  '';
}
