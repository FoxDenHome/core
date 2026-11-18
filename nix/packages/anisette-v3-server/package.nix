{ pkgs, ... }:
pkgs.buildDubPackage {
  pname = "anisette-v3-server";
  version = "2.2.2-unstable-2026-09-23";

  src = pkgs.fetchFromGitHub {
    owner = "Dadoum";
    repo = "anisette-v3-server";
    rev = "684895737aaf1a1c4586fcd5b67509ffd500a36c";
    hash = "sha256-qe5u6sOqlFyHTOR5oYrzzYVJa/o8Tg/G4MWspBZMruo=";
  };

  # Regenerate with `nix run nixpkgs#dub-to-nix > dub-lock.json` in the source tree
  dubLock = ./dub-lock.json;

  nativeBuildInputs = [ pkgs.pkg-config ];

  buildInputs = with pkgs; [
    openssl
    zlib
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 anisette-v3-server -t $out/bin
    runHook postInstall
  '';

  meta.mainProgram = "anisette-v3-server";
}
