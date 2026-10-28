{ nixpkgs, ... }:
let
  isNativeVLAN = vlan: vlan < 16;

  # The gateway VIP, then each router's own address in case VRRP breaks.
  # IPv4 goes first as glibc only reads the first three nameservers.
  mkNameservers =
    vlan:
    if isNativeVLAN vlan then
      [
        "10.${toString vlan}.0.1"
        "10.${toString vlan}.1.1"
        "10.${toString vlan}.1.2"
        "fd2c:f4cb:63be:${toString vlan}\::1"
        "fd2c:f4cb:63be:${toString vlan}\::101"
        "fd2c:f4cb:63be:${toString vlan}\::102"
      ]
    else
      [ ];

  # Same as DHCP hands out: ntpi on LAN, then each router directly
  mkTimeServers =
    vlan:
    if isNativeVLAN vlan then
      (if vlan == 2 then [ "10.2.1.123" ] else [ ])
      ++ [
        "10.${toString vlan}.1.1"
        "10.${toString vlan}.1.2"
      ]
    else
      [ ];

  mkRoutes =
    vlan:
    if isNativeVLAN vlan then
      [
        {
          Destination = "0.0.0.0/0";
          Gateway = "10.${toString vlan}.0.1";
        }
      ]
    else
      [ ];
in
{
  inherit mkNameservers mkTimeServers mkRoutes;

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
            root = ifcfg.interface;
            rootPvid = ifcfg.pvid;
          }
          // commonConfig;
          bridge = {
            bridge = ifcfg.interface;
          }
          // commonConfig;
          macvlan = {
            root = ifcfg.interface;
            rootPvid = ifcfg.pvid;
          }
          // commonConfig;
          ipvlan = {
            root = ifcfg.interface;
            rootPvid = ifcfg.pvid;
          }
          // commonConfig;
        };
        routes = mkRoutes vlan;
      } cfg;
    }
  );
}
