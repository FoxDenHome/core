{
  lib,
  pkgs,
  ...
}:
let
  src =
    let
      src = pkgs.fetchFromGitHub {
        name = "acme";
        owner = "nginx";
        repo = "nginx-acme";
        rev = "v0.1.1";
        hash = "sha256-wnO+lDhtAvBYlaN9vg6spSsfqgHhueODeTkuWKBFswc=";
      };
      combined =
        pkgs.runCommand "vendored-repo"
          {
            nativeBuildInputs = [
              pkgs.rustPlatform.cargoSetupHook
            ];
            cargoDeps = pkgs.rustPlatform.importCargoLock {
              lockFile = "${src}/Cargo.lock";
              outputHashes = {
                "nginx-sys-0.5.0" = "sha256-nyJofVcObsWLVe/bYCM0W7oeKwN4PlDe/ue74En+zAY=";
              };
            };
          }
          ''
            mkdir -p $out
            cp -r ${src}/* $out/

            runHook postUnpack
            cp -r cargo-vendor-dir $out/
            cp -r .cargo $out/
          '';
    in
    combined;
in
pkgs.stdenv.mkDerivation {
  inherit src;
  name = "acme";

  preConfigure = ''
    export NGX_RUSTC_OPT="--config ${src}/.cargo/config.toml"
    export OPENSSL_NO_VENDOR=1
  '';

  inputs = with pkgs; [
    openssl
    cargo
    rustPlatform.bindgenHook
    rustPlatform.cargoSetupHook
    rustPlatform.maturinBuildHook
    rustc
    pkg-config
  ];

  meta = with lib; {
    description = "An NGINX module with the implementation of the automatic certificate management (ACMEv2) protocol";
    homepage = "https://github.com/nginx/nginx-acme";
    license = with licenses; [ asl20 ];
    maintainers = with maintainers; [ nyanloutre ];
  };
}
