{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "92d0bed66705d14112e6d6160d63e33e3bfedc4d";
  hash = "sha256-3dqMg8stPTTF7qXxtFqL4Bjkx1DRv1XvCdymGbpzZb4=";
}
