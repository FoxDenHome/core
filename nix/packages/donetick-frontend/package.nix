{ pkgs, ... }:
let
  version = "1.2.16";
in
pkgs.buildNpmPackage {
  pname = "donetick-frontend";
  inherit version;
  src = pkgs.fetchFromGitHub {
    repo = "frontend";
    owner = "donetick";
    rev = "v${version}";
    hash = "sha256-DGOTqVJeybyPqDnb9PnAlZfyeGnFrzMclep9vp6ZBV0=";
  };
  # We keep a local package-lock.json because the upstream one doesn't have all the hashes...
  npmDeps = pkgs.importNpmLock { npmRoot = ./.; };
  npmConfigHook = pkgs.importNpmLock.npmConfigHook;

  preBuild = ''
    cp -fv ${./package.json} ./package.json
    cp -fv ${./package-lock.json}  ./package-lock.json
  '';

  npmFlags = [ "--ignore-scripts" ];
  npmBuildScript = "build-selfhosted";

  installPhase = ''
    mkdir -p $out/share
    mv dist $out/share/donetick-frontend
  '';
}
