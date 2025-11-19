{ lib, ... }:
let
  recordFiles = lib.attrsets.attrNames (builtins.readDir ./records);
in
{
  config.foxDen.dns.records = lib.flatten (
    map (
      fileName:
      map
        (
          valueRaw:
          let
            parts = lib.strings.splitString " " valueRaw;
          in
          {
            fqdn = fileName;
            ttl = 3600;
            type = "SSHFP";
            horizon = "*";
            algorithm = lib.strings.toIntBase10 (builtins.elemAt parts 0);
            fptype = lib.strings.toIntBase10 (builtins.elemAt parts 1);
            value = builtins.elemAt parts 2;
          }
        )
        (
          lib.lists.filter (x: x != "") (
            lib.strings.splitString "\n" (builtins.readFile ./records/${fileName})
          )
        )
    ) recordFiles
  );
}
