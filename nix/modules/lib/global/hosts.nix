{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  globalConfig = foxDenLib.global.config;

  getInterfaces =
    nixosConfigurations:
    getInterfacesFromHosts (globalConfig.getAttrSet [ "foxDen" "hosts" "hosts" ] nixosConfigurations);
  getInterfacesFromHosts =
    hosts:
    lib.flatten (
      map (
        host:
        map (
          iface:
          iface.value
          // {
            name = iface.name;
            host = host.name;
          }
        ) (lib.attrsets.attrsToList host.value.interfaces)
      ) (lib.attrsets.attrsToList hosts)
    );
in
{
  inherit getInterfaces getInterfacesFromHosts;
  getGateways =
    nixosConfigurations:
    lib.lists.unique (map (iface: iface.gateway) (getInterfaces nixosConfigurations));

  getIPReverses =
    nixosConfigurations:
    let
      providers = globalConfig.get [ "foxDen" "hosts" "hostingProvider" ] nixosConfigurations;
      ipReverseCfg = globalConfig.get [ "foxDen" "hosts" "ipReverses" ] nixosConfigurations;
    in
    nixpkgs.lib.genAttrs (nixpkgs.lib.lists.uniqueStrings (nixpkgs.lib.attrsets.attrValues providers)) (
      provider: nixpkgs.lib.attrsets.filterAttrs (host: value: providers.${host} == provider) ipReverseCfg
    );
}
