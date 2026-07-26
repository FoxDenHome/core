{ pkgs, ... }:
let
  version = "0.1.76";
in
pkgs.buildGoModule {
  pname = "donetick-server";
  inherit version;
  src = pkgs.fetchFromGitHub {
    repo = "donetick";
    owner = "donetick";
    rev = "v${version}";
    hash = "sha256-erko77j6yPmDbEO0pxYu7GQLzKEAFOXn8ZcAccENjew=";
  };
  vendorHash = "sha256-4Ho9lIWk80k+6wVCk27EPYdD7eDC0SUXR9PcIAVmBRA=";

  buildInputs = [ ];
  ldflags = [ "-s -w" ];

  preBuild = ''
    for pfile in ${./patches}/*.patch; do
      echo "Applying patch $(basename "$pfile")"
      patch -p1 -i $pfile
    done
  '';

  postInstall = ''
    mv $out/bin/core $out/bin/donetick-server
  '';
}
