{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "fb7d89dc0050e4473a1b0fea76272e5484623200";
  hash = "sha256-pXywA5ppwnS4x2v7TTqFKgIYRbWrpSYY4PeouA20gR0=";
}
