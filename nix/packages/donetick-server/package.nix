{ pkgs, ... }:
let
  version = "0.1.75";
  feVersion = "1.2.16";

  frontend = pkgs.buildNpmPackage {
    pname = "donetick-frontend";
    version = feVersion;
    src = pkgs.fetchFromGitHub {
      repo = "frontend";
      owner = "donetick";
      rev = "v${feVersion}";
      hash = "sha256-DGOTqVJeybyPqDnb9PnAlZfyeGnFrzMclep9vp6ZBV0=";
    };
    # We keep a local package-lock.json because the upstream one doesn't have all the hashes...
    npmDeps = pkgs.importNpmLock { npmRoot = ./.; };
    npmConfigHook = pkgs.importNpmLock.npmConfigHook;
  };
in
(pkgs.buildGoModule {
  pname = "donetick-server";
  inherit version;
  src = pkgs.fetchFromGitHub {
    repo = "donetick";
    owner = "donetick";
    rev = "v${version}";
    hash = "sha256-UbL/bvh0tSxtYKIL83zsZs/PVLwlAaGqiMKy7/hQD/s=";
  };
  vendorHash = "sha256-4Ho9lIWk80k+6wVCk27EPYdD7eDC0SUXR9PcIAVmBRA=";

  buildInputs = [ ];
  ldflags = [ "-s -w" ];

  postInstall = ''
    mv $out/bin/core $out/bin/donetick-server
  '';
}) // {
  inherit frontend;
}
