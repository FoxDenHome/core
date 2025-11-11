{ nixpkgs, ... }:
let
  mkShortHash = (len: str: builtins.substring 0 len (builtins.hashString "sha256" str));

  isPrivateIPv4 = (
    ip:
    let
      segments = nixpkgs.lib.strings.splitString "." ip;
      first = nixpkgs.lib.strings.toIntBase10 (builtins.elemAt segments 0);
      second = nixpkgs.lib.strings.toIntBase10 (builtins.elemAt segments 1);
    in
    (first == 10)
    || (first == 172 && (second >= 16 && second <= 31))
    || (first == 192 && second == 168)
    || (first == 100 && (second >= 64 && second <= 127))
  ); # Technically CGNAT, but also internal

  isPrivateIPv6 = (
    ip:
    let
      segments = nixpkgs.lib.strings.splitString ":" ip;
      first = builtins.elemAt segments 0;
    in
    ((builtins.stringLength first) == 4)
    && ((nixpkgs.lib.strings.hasPrefix "fd" first) || (nixpkgs.lib.strings.hasPrefix "fc" first))
  );

  isIPv6 = nixpkgs.lib.strings.hasInfix ":";

  ipv4Ptr = (
    ip:
    let
      segments = nixpkgs.lib.strings.splitString "." (removeIPCidr ip);
      host = nixpkgs.lib.strings.concatStringsSep "." (nixpkgs.lib.lists.reverseList segments);
    in
    "${host}.in-addr.arpa"
  );

  ipv6Ptr = (
    ip:
    let
      expanded = (nixpkgs.lib.network.ipv6.fromString ip).address; # This removes any "::" contractions
      parts = nixpkgs.lib.strings.splitString ":" expanded; # Split it into the [0-4]-hex segments
      partsWithDot = map (
        part:
        let
          partPadded = "0000${part}";
          digits = nixpkgs.lib.substring (builtins.stringLength partPadded - 4) 4 partPadded;
        in
        (nixpkgs.lib.strings.stringToCharacters digits)
      ) parts;
    in
    (nixpkgs.lib.strings.concatStringsSep "." (
      nixpkgs.lib.lists.reverseList (nixpkgs.lib.lists.flatten partsWithDot)
    ))
    + ".ip6.arpa"
  );

  ipv4CidrNetmaskMap = [
    "0.0.0.0"
    "128.0.0.0"
    "192.0.0.0"
    "224.0.0.0"
    "240.0.0.0"
    "248.0.0.0"
    "252.0.0.0"
    "254.0.0.0"
    "255.0.0.0"
    "255.128.0.0"
    "255.192.0.0"
    "255.224.0.0"
    "255.240.0.0"
    "255.248.0.0"
    "255.252.0.0"
    "255.254.0.0"
    "255.255.0.0"
    "255.255.128.0"
    "255.255.192.0"
    "255.255.224.0"
    "255.255.240.0"
    "255.255.248.0"
    "255.255.252.0"
    "255.255.254.0"
    "255.255.255.0"
    "255.255.255.128"
    "255.255.255.192"
    "255.255.255.224"
    "255.255.255.240"
    "255.255.255.248"
    "255.255.255.252"
    "255.255.255.254"
    "255.255.255.255"
  ];

  removeIPCidr = (ip: builtins.elemAt (nixpkgs.lib.strings.splitString "/" ip) 0);
  getIPCidr = (
    ip:
    let
      ipSplit = nixpkgs.lib.strings.splitString "/" ip;
    in
    builtins.elemAt ipSplit ((nixpkgs.lib.lists.length ipSplit) - 1)
  );
in
{
  inherit
    isIPv6
    mkShortHash
    removeIPCidr
    getIPCidr
    ;
  isPrivateIP = (ip: if (isIPv6 ip) then (isPrivateIPv6 ip) else (isPrivateIPv4 ip));
  isIPv4 = (ip: !isIPv6 ip);
  addHostCidr = (
    ipRaw:
    let
      ip = removeIPCidr ipRaw;
    in
    if (isIPv6 ip) then "${ip}/128" else "${ip}/32"
  );
  ipv4Netmask = (
    ipOrCidr:
    let
      cidr = nixpkgs.lib.strings.toIntBase10 (getIPCidr ipOrCidr);
    in
    builtins.elemAt ipv4CidrNetmaskMap cidr
  );

  bracketIPv6 = (ip: if (isIPv6 ip) then "[${ip}]" else ip);
  mkPtr = (ip: if (isIPv6 ip) then ipv6Ptr ip else ipv4Ptr ip);
}
