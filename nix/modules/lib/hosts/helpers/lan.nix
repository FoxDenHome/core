{ nixpkgs, ... }:
let
  isNativeVLAN = vlan: vlan < 16;

  mkNameservers =
    vlan:
    if isNativeVLAN vlan then
      [
        "10.${builtins.toString vlan}.0.53"
        "fd2c:f4cb:63be:${builtins.toString vlan}\::35"
      ]
    else
      throw "Must set explicit nameservers for non-native VLAN ID";

  mkRoutes =
    vlan:
    if isNativeVLAN vlan then
      [
        {
          Destination = "0.0.0.0/0";
          Gateway = "10.${builtins.toString vlan}.0.1";
        }
      ]
    else
      throw "Must set explicit routes for non-native VLAN ID";
in
{
  inherit mkNameservers mkRoutes;

  mkVlanHost = (
    ifcfg: vlan: cfg:
    let
      driver = ifcfg.defaultDriver or "bridge";
      commonConfig = {
        mtu = ifcfg.mtu;
        vlan = vlan;
      };
    in
    {
      nameservers = mkNameservers vlan;
      interfaces.default = nixpkgs.lib.recursiveUpdate {
        driver = {
          name = driver;
          sriov = {
            root = ifcfg.phyIface;
            rootPvid = ifcfg.phyPvid;
          }
          // commonConfig;
          bridge = {
            bridge = ifcfg.interface;
          }
          // commonConfig;
        };
        routes = mkRoutes vlan;
      } cfg;
    }
  );
}
