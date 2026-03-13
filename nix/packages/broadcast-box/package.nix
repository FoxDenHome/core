{
  lib,
  pkgs,
  ...
}:
let
  name = "broadcast-box";
  version = "2.0.2-dori";

  src = pkgs.fetchFromGitHub {
    repo = "broadcast-box";
    owner = "Glimesh";
    rev = "d4d186a765f6e70e4303660cd387be7e96a028a9";
    hash = "sha256-VhigcFhyiYJVgMmoYsUpt0Q0Lg2u5fRCdi5rCUcsnM4=";
  };

  frontend = pkgs.buildNpmPackage {
    inherit version;
    pname = "${name}-web";
    src = "${src}/web";

    npmDeps = pkgs.importNpmLock { npmRoot = ./.; };
    npmConfigHook = pkgs.importNpmLock.npmConfigHook;

    preBuild = ''
      # The VITE_API_PATH environment variable is needed
      cp "${src}/.env.production" ../
    '';
    installPhase = ''
      mkdir -p $out
      cp -r build $out
    '';
  };
in
pkgs.buildGoModule {
  inherit version src frontend;
  pname = name;
  vendorHash = "sha256-VvUFeleuCSm4ikkxOXpd+tMLTf2ZHR6V8gDGtKXTiV4=";
  proxyVendor = true; # fixes darwin/linux hash mismatch

  postPatch = ''
    substituteInPlace internal/environment/environment.go \
      --replace-fail './web/build' '${placeholder "out"}/share'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share
    cp -r $frontend/build/* $out/share

    install -Dm755 $GOPATH/bin/broadcast-box -t $out/bin

    runHook postInstall
  '';

  meta = {
    description = "WebRTC broadcast server";
    homepage = "https://github.com/Glimesh/broadcast-box";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ JManch ];
    platforms = lib.platforms.unix;
    mainProgram = "broadcast-box";
  };
}
