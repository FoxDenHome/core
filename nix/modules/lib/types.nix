{ nixpkgs, ... }:
let
  types = nixpkgs.lib.types;

  validIPv4Segment = (
    s:
    let
      n = nixpkgs.lib.strings.toIntBase10 s;
    in
    n >= 0 && n <= 255
  );

  ipv4Check = (
    ip:
    let
      cidrSplit = nixpkgs.lib.strings.splitString "/" ip;
      segments = nixpkgs.lib.strings.splitString "." (builtins.elemAt cidrSplit 0);

      segmentsValidTry = builtins.tryEval (nixpkgs.lib.lists.all validIPv4Segment segments);
      segmentsValid = segmentsValidTry.success && segmentsValidTry.value;

      cidr = nixpkgs.lib.strings.toIntBase10 (builtins.elemAt cidrSplit 1);
      cidrValidTry = builtins.tryEval (cidr >= 0 && cidr <= 32);
      cidrValid = nixpkgs.lib.lists.length cidrSplit < 2 || (cidrValidTry.success && cidrValidTry.value);
    in
    segmentsValid
    && cidrValid
    && (nixpkgs.lib.lists.length segments == 4)
    && (nixpkgs.lib.lists.length cidrSplit <= 2)
  );

  ipv6Check = (
    ip:
    let
      ipv6 = nixpkgs.lib.network.ipv6.fromString ip;
    in
    (builtins.tryEval ipv6).success
  );

  ipCidrCheck = (
    withCidr: check: ip:
    (check ip) && (withCidr == (nixpkgs.lib.strings.hasInfix "/" ip))
  );

  ipv4WithoutCidr = types.addCheck types.str (ipCidrCheck false ipv4Check);
  ipv4WithCidr = types.addCheck types.str (ipCidrCheck true ipv4Check);
  ipv6WithoutCidr = types.addCheck types.str (ipCidrCheck false ipv6Check);
  ipv6WithCidr = types.addCheck types.str (ipCidrCheck true ipv6Check);
  ipv4 = types.addCheck types.str ipv4Check;
  ipv6 = types.addCheck types.str ipv6Check;
in
{
  ipv4WithoutCidr = ipv4WithoutCidr;
  ipv4WithCidr = ipv4WithCidr;
  ipv4 = ipv4;
  ipv6WithoutCidr = ipv6WithoutCidr;
  ipv6WithCidr = ipv6WithCidr;
  ipv6 = ipv6;

  ip = types.either ipv4 ipv6;
  ipWithCidr = types.either ipv4WithCidr ipv6WithCidr;
  ipWithoutCidr = types.either ipv4WithoutCidr ipv6WithoutCidr;

  ipWithPort = types.addCheck types.str (
    ipPort:
    let
      split = builtins.match "^(\\[[0-9a-fA-F:]+]|[0-9.]+):([0-9]+)$" ipPort;

      port = nixpkgs.lib.strings.toIntBase10 (builtins.elemAt split 1);
      portValidTry = builtins.tryEval (port > 0 && port <= 65535);
      portValid = portValidTry.success && portValidTry.value;

      ip = (
        nixpkgs.lib.strings.removeSuffix "]" (
          nixpkgs.lib.strings.removePrefix "[" (builtins.elemAt split 0)
        )
      );
    in
    split != null
    && (nixpkgs.lib.lists.length split == 2)
    && portValid
    && ((ipv4Check ip) || (ipv6Check ip))
  );
}
