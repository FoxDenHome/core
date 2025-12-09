{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "433c320b2130255ee5aeebc5d36ac05dff124b8f";
  hash = "sha256-9nnBzWNAkYd6QaCtToxQk5z8PUiznXdwGaywIlXHUjY=";
}
