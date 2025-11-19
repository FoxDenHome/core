{ lib, ... }:
let
  mkView = suffix: ";include('config'); return view(FoxDenLocal('${suffix}'));";
  mkDevice = name: suffix4: suffix6: [
    {
      name = "${name}.foxden.network";
      ttl = 30;
      type = "LUA A";
      value = mkView suffix4;
      horizon = "internal";
    }
    {
      name = "${name}.foxden.network";
      ttl = 30;
      type = "LUA AAAA";
      value = mkView suffix6;
      horizon = "internal";
    }
  ];
in
{
  config.foxDen.dns.records = lib.flatten [
    (mkDevice "gateway" "0.1" "0001")
    (mkDevice "dns" "0.53" "0035")
    (mkDevice "ntp" "0.12" "007b")
    (mkDevice "router" "1.1" "0101")
    (mkDevice "router-backup" "1.2" "0102")
    (mkDevice "ntpi" "1.123" "017b")
    [
      {
        name = "ecstest.foxden.network";
        ttl = 0;
        type = "LUA TXT";
        value = "bestwho:toString()";
        horizon = "internal";
      }
    ]
  ];
}
