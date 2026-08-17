{
  lib,
  pkgs,
  ...
}:
let
  name = "sas3temp";
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = name;
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = with pkgs; [
    cargo
    rustc
  ];

  env = {
    CARGO_NET_OFFLINE = "true";
  };
  buildPhase = ''
    cargo build --release
  '';
  installPhase = ''
    mkdir -p $out/bin/
    cp target/release/${name} $out/bin/
  '';

  meta = {
    description = "LSI SAS3 temperature prometheus exporter";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})
