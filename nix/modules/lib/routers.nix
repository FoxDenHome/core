{ nixpkgs, ... }:
let
  lib = nixpkgs.lib;

  ula = "fd2c:f4cb:63be";

  # The internal routers. Each one's own addresses use its index as host part
  # (10.<vlan>.1.<index>, <ula>:<vlan>::10<index>) and it hands out its own
  # half of every redundant VLAN's DHCP range.
  routers = {
    router = {
      index = 1;
      publicIpv6 = "2a0e:7d44:f069:a00::/56";
      tunnelIpv6 = "2a0e:7d44:f069:fa00";
    };
    router-backup = {
      index = 2;
      publicIpv6 = "2a0e:7d44:f069:b00::/56";
      tunnelIpv6 = "2a0e:7d44:f069:fb00";
    };
  };

  # Addresses held by whichever router is VRRP master, as 10.<vlan>.<ipv4> and <ula>:<vlan>::<ipv6>.
  # The gateway VIP also serves DNS, NTP and the mailer.
  vips = [
    {
      name = "gateway";
      vrid = 1;
      ipv4 = "0.1";
      vrid6 = 2;
      ipv6 = "1";
    }
  ];

  # A VLAN of the 10.<id>.0.0/16 + <ula>:<id>::/64 plan. Redundant ones get the
  # VIPs above, the others are routed by the primary router only.
  mkPlanVlan =
    {
      name,
      id,
      mtu ? 9000,
      native ? false,
      redundant ? true,
      ipv6 ? true,
      leaseTime ? "1h",
      interfaceList ? "iface-${name}",
      # Preferred NTP servers handed out over DHCPv4, ahead of the routers
      ntp ? [ ],
    }:
    let
      net = "10.${toString id}";
      net6 = "${ula}:${toString id}:";
      primaryAddr = "${net}.1.1";
      gateway = if redundant then "${net}.0.1" else primaryAddr;
      # Each router's own address in index order, as fallback for when VRRP breaks
      routerAddrs =
        if redundant then
          map (router: "${net}.1.${toString router.index}") (
            lib.sort (a: b: a.index < b.index) (lib.attrValues routers)
          )
        else
          [ primaryAddr ];
    in
    {
      inherit
        name
        mtu
        native
        leaseTime
        interfaceList
        ;
      vlanId = id;
      ipv4 = {
        network = "${net}.0.0/16";
        inherit gateway;
        dns = lib.unique ([ gateway ] ++ routerAddrs);
        ntp = ntp ++ routerAddrs;
        domain = "foxden.network";
      };
      ipv6 =
        if ipv6 then
          {
            network = "${net6}:/64";
            dns = if redundant then "${net6}:1" else "${net6}:101";
          }
        else
          null;
      vips =
        if redundant then
          map (
            vip:
            {
              inherit (vip) name vrid;
              ipv4 = "${net}.${vip.ipv4}";
            }
            // lib.optionalAttrs (vip ? vrid6) {
              inherit (vip) vrid6;
              ipv6 = "${net6}:${vip.ipv6}";
            }
          ) vips
        else
          [ ];
      routers = lib.mapAttrs (
        _: router:
        let
          idx = router.index;
          poolStart = 50 + 50 * idx;
          hasPool = redundant || idx == 1;
        in
        {
          ipv4 = "${net}.1.${toString idx}/16";
          ipv6 = if ipv6 then "${net6}:10${toString idx}/64" else null;
          pool =
            if hasPool then "${net}.${toString poolStart}.0-${net}.${toString (poolStart + 49)}.255" else null;
        }
      ) routers;
    };

  vlans = [
    (mkPlanVlan {
      name = "mgmt";
      id = 1;
      native = true;
    })
    (mkPlanVlan {
      name = "lan";
      id = 2;
      leaseTime = "1d";
      # ntpi, falling back to the routers (IPv6 would need DHCPv6)
      ntp = [ "10.2.1.123" ];
    })
    (mkPlanVlan {
      name = "dmz";
      id = 3;
    })
    (mkPlanVlan {
      name = "labnet";
      id = 4;
    })
    (mkPlanVlan {
      name = "security";
      id = 5;
    })
    (mkPlanVlan {
      name = "hypervisor";
      id = 6;
    })
    (mkPlanVlan {
      name = "retro";
      id = 7;
      mtu = 1500;
      redundant = false;
      ipv6 = false;
      interfaceList = "zone-local";
    })
    # Cursed Silicon's homelab network, see bengalfox/cghmn.nix
    {
      name = "cghmn";
      vlanId = 2001;
      mtu = 1280;
      native = false;
      leaseTime = "1h";
      interfaceList = "iface-cghmn";
      ipv4 = {
        network = "100.68.41.0/24";
        gateway = "100.68.41.1";
        dns = [ "100.68.41.1" ];
        ntp = null;
        domain = null;
      };
      ipv6 = null;
      vips = [ ];
      routers = lib.mapAttrs (_: router: {
        ipv4 = "100.68.41.${toString router.index}/24";
        ipv6 = null;
        pool = if router.index == 1 then "100.68.41.200-100.68.41.250" else null;
      }) routers;
    }
    # Wake-on-LAN only, no addresses
    {
      name = "wolnet";
      vlanId = 666;
      mtu = 1500;
      native = false;
      leaseTime = null;
      interfaceList = null;
      ipv4 = null;
      ipv6 = null;
      vips = [ ];
      routers = lib.mapAttrs (_: _: {
        ipv4 = null;
        ipv6 = null;
        pool = null;
      }) routers;
    }
  ];

  # Addresses on the routers' non-VLAN interfaces. "local" ones are in the
  # local-ip address list, which the "Local forward" NAT rule matches on.
  mkAddresses =
    router:
    let
      idx = toString router.index;
    in
    [
      {
        interface = "lo";
        address = "${ula}::${idx}/128";
        local = false;
      }
      {
        interface = "wg-vpn";
        address = "10.100.0.1/16";
        local = true;
      }
      {
        interface = "wg-vpn";
        address = "${ula}::a64:1/112";
        local = true;
      }
      {
        interface = "wg-s2s";
        address = "10.99.1.${idx}/16";
        local = true;
      }
      {
        interface = "wg-s2s";
        address = "${ula}::a63:10${idx}/112";
        local = true;
      }
      # Faux external address, see the "Local faux external ingress" NAT rule
      {
        interface = "vlan-lan";
        address = "10.2.6.${idx}/24";
        local = false;
      }
      {
        interface = "6to4-redfox";
        address = "${router.tunnelIpv6}::2/56";
        local = false;
      }
      {
        interface = "wg-s2s";
        address = "10.99.0.1/32";
        local = true;
      }
    ]
    ++ lib.optionals (router.index == 1) [
      {
        interface = "wg-cghmn";
        address = "100.65.0.41/32";
        local = false;
      }
    ];
in
{
  inherit routers vips vlans;

  mkConfig = {
    inherit vlans;
    routers = lib.mapAttrs (
      _: router:
      router
      // {
        addresses = mkAddresses router;
      }
    ) routers;
  };
}
