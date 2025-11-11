{ ... }:
rec {
  mkNameservers = (
    vlan: [
      "10.${builtins.toString vlan}.0.53"
      "fd2c:f4cb:63be:${builtins.toString vlan}\::35"
    ]
  );

  mkRoutes = (
    vlan: [
      {
        Destination = "0.0.0.0/0";
        Gateway = "10.${builtins.toString vlan}.0.1";
      }
    ]
  );

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
      interfaces.default = {
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
      }
      // cfg;
    }
  );
}
