{ lib, ... }:
let
  # The Forgejo runners' job containers (forgejo-runner-container on
  # bengalfox and islandfox), as in modules/nixos/deploy/push.nix
  runnerSubnets = [
    "10.6.11.0/24"
    "fd2c:f4cb:63be:6::b00/120"
  ];

  # What .forgejo/workflows/apply.yml reaches beyond the router that is the
  # runners' gateway: SSH and API of the routers (mikrotik/configure.py), and
  # the foxMail DKIM keys (dns/dns.py). Both routers are listed so it keeps
  # working when the other one holds the VRRP gateway.
  targets = [
    {
      name = "router";
      addresses = [
        "10.2.1.1"
        "fd2c:f4cb:63be:2::101"
      ];
      ports = [
        22
        8728
        9002
      ];
    }
    {
      name = "router-backup";
      addresses = [
        "10.2.1.2"
        "fd2c:f4cb:63be:2::102"
      ];
      ports = [
        22
        8728
        9002
      ];
    }
    {
      name = "redfox";
      addresses = [
        "10.99.10.1"
        "fd2c:f4cb:63be::a63:a01"
      ];
      ports = [
        22
        8728
      ];
    }
    {
      name = "icefox";
      addresses = [
        "10.99.10.2"
        "fd2c:f4cb:63be::a63:a02"
      ];
      ports = [ 9002 ];
    }
  ];
in
{
  # Rules mixing IPv4 and IPv6 are dropped by foxDenLib.global.firewall
  foxDen.firewall.rules = lib.flatten (
    map (
      target:
      map (
        source:
        map (
          destination:
          map (port: {
            table = "filter";
            chain = "forward";
            action = "accept";
            protocol = "tcp";
            dstport = port;
            comment = "ci-apply-${target.name}";
            inherit source destination;
          }) target.ports
        ) target.addresses
      ) runnerSubnets
    ) targets
  );
}
