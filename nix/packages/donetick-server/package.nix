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
  vendorHash = builtins.readFile ./vendor-hash.txt;

  buildInputs = [ ];
  ldflags = [ "-s -w" ];

  postInstall = ''
    mv $out/bin/core $out/bin/donetick-server
  '';
}
