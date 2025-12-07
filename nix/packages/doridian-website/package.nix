{ lib, pkgs, ... }:
let
  subnets = [
    "2a0e:7d44:f000::/40"
    "2a0e:8f02:21c0::/44"
  ];
  location = {
    country = "US";
    state = "US-WA";
    city = "Seattle";
  };

  geofeedData =
    (lib.concatMapStringsSep "\n" (
      subnet: "${subnet},${location.country},${location.state},${location.city},"
    ) subnets)
    + "\n";

  geofeedText = ''
    # Doridian Network geofeed according to RFC 8805
    # Number of networks: ${builtins.toString (lib.length subnets)}
    # Content SHA256 hash (excluding comments): ${builtins.hashString "sha256" geofeedData}
  ''
  + geofeedData
  + "# End of file\n";
in
pkgs.stdenvNoCC.mkDerivation {
  name = "doridian-website";
  version = "1.0.0";
  src = ./files;

  unpackPhase = ''
    cp -r "$src" ./files
  '';

  installPhase = ''
    mkdir -p $out
    cp ${pkgs.writers.writeText "geofeed" geofeedText} $out/geofeed.csv
    cp -r ./files/* $out/
  '';
}
