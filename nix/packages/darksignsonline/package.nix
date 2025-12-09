{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "f74f2c8a3eda558387b248a9cb65c72610e764a5";
  hash = "sha256-DhDMvbMA6jmMTjBupes5l/hhDD2pO7tu9InmKdiFXYE=";
}
