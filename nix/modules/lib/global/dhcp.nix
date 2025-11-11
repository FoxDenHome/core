{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;

  mkForGateway =
    gateway: interfacesAll:
    let
      ifaces = lib.lists.filter (
        iface: iface.mac != null && iface.useDHCP && iface.gateway == gateway
      ) interfacesAll;

      ifaceFirstV4 =
        iface:
        util.removeIPCidr (
          nixpkgs.lib.findFirst (ip: util.isIPv4 ip && util.isPrivateIP ip) "" iface.addresses
        );
      ifaceFirstV6 =
        iface:
        util.removeIPCidr (
          nixpkgs.lib.findFirst (ip: util.isIPv6 ip && util.isPrivateIP ip) "" iface.addresses
        );
    in
    lib.flatten (
      map (
        iface:
        let
          ipv4 = ifaceFirstV4 iface;
          ipv6 = ifaceFirstV6 iface;
          name = "${iface.host}-${iface.name}";
        in
        if ipv4 != "" && ipv6 != "" then
          [
            {
              inherit (iface) mac dhcpv6;
              inherit name ipv4 ipv6;
            }
          ]
        else if ipv4 != "" then
          [
            {
              inherit (iface) mac dhcpv6;
              inherit name ipv4;
            }
          ]
        else if ipv6 != "" then
          [
            {
              inherit (iface) mac dhcpv6;
              inherit name ipv6;
            }
          ]
        else
          [ ]
      ) ifaces
    );
in
{
  make =
    nixosConfigurations:
    let
      interfaces = foxDenLib.global.hosts.getInterfaces nixosConfigurations;
      gateways = foxDenLib.global.hosts.getGateways nixosConfigurations;
    in
    lib.attrsets.genAttrs gateways (gateway: mkForGateway gateway interfaces);
}
