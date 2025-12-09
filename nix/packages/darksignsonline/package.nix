{ pkgs, ... }:
pkgs.fetchFromGitHub {
  owner = "Doridian";
  repo = "DarkSignsOnline";

  name = "darksignsonline";
  version = "1.0.0";

  rev = "b637704fd4436f2b54951ca15a57676db44b4f6a";
  hash = "sha256-/hUVpVHzHZzlxsldO0cRWw9ImcHMjGpG4FPbOVkA1vI=";
}
