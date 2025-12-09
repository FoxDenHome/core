{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "8f177eece910222e3ba83edf34870fa9e6716b82";
  hash = "sha256-3dqMg8stPTTF7qXxtFqL4Bjkx1DRv1XvCdymGbpzZb4=";
}
