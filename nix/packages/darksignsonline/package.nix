{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "8ccbac02f1ca4caf253583e6c05f9387609cbbf3";
  hash = "sha256-bBLRyTzTJGdisl+OIKEn/kbZcDK44wTkvCxZuYsaYLQ=";
}
