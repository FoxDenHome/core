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
}
