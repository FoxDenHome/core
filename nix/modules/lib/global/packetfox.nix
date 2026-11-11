{ foxDenLib, nixpkgs, ... }:
let
  lib = nixpkgs.lib;
  routerCfg = foxDenLib.routers.mkConfig;

  sshfpDir = ../../../systems/x86_64-linux/landevices/sshfp/records;
  sshfp =
    fqdn:
    let
      path = sshfpDir + "/${fqdn}";
    in
    if builtins.pathExists path then
      lib.filter (x: x != "") (lib.splitString "\n" (builtins.readFile path))
    else
      [ ];

  firstFQDN =
    host:
    lib.findFirst (x: x != null) null (
      map (iface: lib.head (iface.dns.fqdns ++ [ null ])) (lib.attrValues host.interfaces)
    );

  # The routers' own addresses: per VLAN, the VIPs and the rest
  routerAddresses =
    name:
    lib.filter (a: a != null) (
      lib.flatten (
        map (
          vlan:
          (lib.optionals (vlan.routers ? ${name}) [
            (vlan.routers.${name}.ipv4 or null)
            (vlan.routers.${name}.ipv6 or null)
          ])
          ++ (lib.flatten (
            map (vip: [
              (vip.ipv4 or null)
              (vip.ipv6 or null)
            ]) (vlan.vips or [ ])
          ))
        ) routerCfg.vlans
      )
      ++ map (a: a.address) routerCfg.routers.${name}.addresses
    );
in
{
  # What pfox needs to know about the network: where it can capture, and
  # every host it can filter for.
  mkConfig =
    nixosConfigurations:
    let
      hostsBySystem = foxDenLib.global.config.get [ "foxDen" "hosts" "hosts" ] nixosConfigurations;
      agentSystems = lib.attrNames (
        lib.filterAttrs (_: enabled: enabled) (
          foxDenLib.global.config.get [ "foxDen" "packetfox" "agent" "enable" ] nixosConfigurations
        )
      );
      allHosts = lib.flatten (
        lib.mapAttrsToList (
          system: hosts: lib.mapAttrsToList (name: host: { inherit name system host; }) hosts
        ) hostsBySystem
      );
    in
    {
      routers = map (name: {
        inherit name;
        address = "${name}.foxden.network:8728";
        username = "pfox";
        addresses = routerAddresses name;
      }) (lib.sortOn (name: routerCfg.routers.${name}.index) (lib.attrNames routerCfg.routers));

      agents = map (
        name:
        let
          address = "${name}.foxden.network";
        in
        {
          inherit name address;
          user = "pfox";
          sshfp = sshfp address;
        }
      ) agentSystems;

      # UniFi APs; they run tcpdump over SSH with the controller's device
      # credentials
      aps = map (
        e:
        let
          address = firstFQDN e.host;
        in
        {
          inherit (e) name system;
          inherit address;
          sshfp = sshfp address;
        }
      ) (lib.filter (e: lib.hasPrefix "ap-" e.name && e.host.ssh && firstFQDN e.host != null) allHosts);

      endpoints = map (e: {
        inherit (e) name system;
        netns = if e.host.netns && lib.elem e.system agentSystems then "host-${e.name}" else "";
        interfaces = lib.mapAttrsToList (name: iface: {
          inherit name;
          inherit (iface) addresses mac;
          fqdns = iface.dns.fqdns;
        }) e.host.interfaces;
      }) allHosts;
    };
}
