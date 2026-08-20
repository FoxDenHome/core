{
  lib,
  pkgs,
  ...
}:
let
  name = "broadcast-box";
  version = "2.0.3-dori";

  src = pkgs.fetchFromGitHub {
    repo = "broadcast-box";
    owner = "Glimesh";
    rev = "9f43de20e802ee8acc826c3999e021e736dd2a89";
    hash = "sha256-N9aqqvYZg3Hx5xymaMzQ0eEhQycGdyP/weVpIw2R4bc=";
  };

  frontend = pkgs.buildNpmPackage {
    inherit version;
    pname = "${name}-web";
    src = "${src}/web";

    npmDeps = pkgs.importNpmLock { npmRoot = ./.; };
    npmConfigHook = pkgs.importNpmLock.npmConfigHook;

    preBuild = ''
      # The VITE_API_PATH environment variable is needed
      patch -i ${./transient-ice-disconnect.patch} -p3
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
  vendorHash = "sha256-YHFPZuZlgPrYo072pBU47vfGKwjr62YPCT5S3gAjhuI=";
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
