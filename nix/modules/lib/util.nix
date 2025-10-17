{ nixpkgs, ... }:
let
  mkShortHash = (len: str:
    builtins.substring 0 len (builtins.hashString "sha256" str));

  isPrivateIPv4 = (ip: let
    segments = nixpkgs.lib.strings.splitString "." ip;
    first = nixpkgs.lib.strings.toIntBase10 (builtins.elemAt segments 0);
    second = nixpkgs.lib.strings.toIntBase10 (builtins.elemAt segments 1);
  in
    (first == 10) ||
    (first == 172 && (second >= 16 && second <= 31)) ||
    (first == 192 && second == 168) ||
    (first == 100 && (second >= 64 && second <= 127))); # Technically CGNAT, but also internal

  isPrivateIPv6 = (ip:
    (nixpkgs.lib.strings.hasPrefix "fd" ip) ||
    (nixpkgs.lib.strings.hasPrefix "fc" ip));

  isIPv6 = nixpkgs.lib.strings.hasInfix ":";

  ipv4Ptr = (ip: let
    segments = nixpkgs.lib.strings.splitString "." (removeIPCidr ip);
    host = nixpkgs.lib.strings.concatStringsSep "." (nixpkgs.lib.lists.reverseList segments);
  in "${host}.in-addr.arpa");

  ipv6Ptr = (ip: let
    expanded = (nixpkgs.lib.network.ipv6.fromString ip).address; # This removes any "::" contractions
    parts = nixpkgs.lib.strings.splitString ":" expanded; # Split it into the [0-4]-hex segments
    partsWithDot = map (part: let
      partPadded = "0000${part}";
      digits = nixpkgs.lib.substring (builtins.stringLength partPadded - 4) 4 partPadded;
    in (nixpkgs.lib.strings.stringToCharacters digits)) parts;
  in (nixpkgs.lib.strings.concatStringsSep "."
        (nixpkgs.lib.lists.reverseList
          (nixpkgs.lib.lists.flatten partsWithDot))) + ".ip6.arpa");

  removeIPCidr = (ip: builtins.elemAt (nixpkgs.lib.strings.splitString "/" ip) 0);
in
{
  mkShortHash = mkShortHash;

  isPrivateIP = (ip: if (isIPv6 ip) then (isPrivateIPv6 ip) else (isPrivateIPv4 ip));

  isIPv6 = isIPv6;
  isIPv4 = (ip: !isIPv6 ip);

  removeIPCidr = removeIPCidr;
  addHostCidr = (ipRaw: let
    ip = removeIPCidr ipRaw;
  in if (isIPv6 ip) then "${ip}/128" else "${ip}/32");

  bracketIPv6 = (ip: if (isIPv6 ip) then "[${ip}]" else ip);

  mkPtr = (ip: if (isIPv6 ip) then ipv6Ptr ip else ipv4Ptr ip);
}
