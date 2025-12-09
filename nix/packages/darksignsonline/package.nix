{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "be4be86dece35298bbf081dc7bbd7640bdb7c3f7";
  hash = "sha256-bBLRyTzTJGdisl+OIKEn/kbZcDK44wTkvCxZuYsaYLQ=";
}
