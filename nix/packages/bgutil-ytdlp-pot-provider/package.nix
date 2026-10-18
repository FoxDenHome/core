{ pkgs, ... }:
let
  version = "2.0.2";
  src = pkgs.fetchFromGitHub {
    owner = "Brainicism";
    repo = "bgutil-ytdlp-pot-provider";
    rev = version;
    hash = "sha256-rV85jle5R8je7iR8uZaXEdDuQEh2lf/Eoht+9k6bpC4=";
  };

  # yt-dlp plugin, version-locked to the server below (nixpkgs only ships an older plugin)
  plugin = pkgs.python3Packages.buildPythonPackage {
    pname = "bgutil-ytdlp-pot-provider-plugin";
    inherit version src;
    pyproject = true;
    sourceRoot = "${src.name}/plugin";
    build-system = [ pkgs.python3Packages.hatchling ];
    postPatch = "cp ../README.md README.md";
    doCheck = false;
  };
in
pkgs.buildNpmPackage {
  pname = "bgutil-ytdlp-pot-provider";
  inherit version src;
  sourceRoot = "${src.name}/server";

  npmDepsHash = "sha256-Ffse1RelOmLpfYM50zZ/xqkfy9l2TGYE8CumK0b9cQg=";

  nativeBuildInputs = with pkgs; [
    pkg-config
    python3
    makeWrapper
  ];
  # node-canvas native build
  buildInputs = with pkgs; [
    cairo
    pango
    pixman
    libjpeg
    giflib
    librsvg
  ];

  buildPhase = ''
    runHook preBuild
    npx tsc
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --no-audit --no-fund
    mkdir -p $out/lib/bgutil-ytdlp-pot-provider $out/bin
    cp -r build node_modules package.json $out/lib/bgutil-ytdlp-pot-provider/
    makeWrapper ${pkgs.nodejs}/bin/node $out/bin/bgutil-pot-server \
      --add-flags $out/lib/bgutil-ytdlp-pot-provider/build/main.js
    runHook postInstall
  '';

  passthru = { inherit plugin; };
}
