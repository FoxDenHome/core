{ lib, ... } :
let
  vlans = [1 2 3 4 5 6 7 8 9];
in
{
  config.foxDen.dns.records = lib.flatten (map (vlan: [

  ]) vlans);
}
