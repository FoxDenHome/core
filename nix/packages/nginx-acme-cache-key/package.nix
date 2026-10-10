{
  lib,
  pkgs,
  ...
}:
let
  name = "nginx-acme-cache-key";
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = name;
  version = "1.0.0";

  src = ./.;

  cargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = with pkgs; [
    cargo
    rustc
    rustPlatform.cargoSetupHook
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
    description = "ACME cache key precomputer";
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
