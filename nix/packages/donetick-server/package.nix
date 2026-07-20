{ pkgs, ... }:
let
  version = "0.1.76-beta.20";
in
pkgs.buildGoModule {
  pname = "donetick-server";
  inherit version;
  src = pkgs.fetchFromGitHub {
    repo = "donetick";
    owner = "donetick";
    rev = "v${version}";
    hash = "sha256-2dR1h1iRLDUorrcnp42PTR62m1OPz2ZcGw/FZBZF670=";
  };
  vendorHash = "sha256-4Ho9lIWk80k+6wVCk27EPYdD7eDC0SUXR9PcIAVmBRA=";

  buildInputs = [ ];
  ldflags = [ "-s -w" ];

  postInstall = ''
    mv $out/bin/core $out/bin/donetick-server
  '';
}
