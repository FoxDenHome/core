{ pkgs, ... }:
let
  version = "0.1.75";
in
pkgs.buildGoModule {
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
}
