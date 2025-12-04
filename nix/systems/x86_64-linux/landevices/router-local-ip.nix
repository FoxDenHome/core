{ lib, ... }:
let
  mkView = suffix: "view(FoxDenLocal('${suffix}'))";
  mkDevice = name: suffix4: suffix6: [
    {
      fqdn = "${name}.foxden.network";
      ttl = 30;
      type = "LUA A";
      value = mkView suffix4;
      horizon = "internal";
    }
    {
      fqdn = "${name}.foxden.network";
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
    (mkDevice "ntp" "0.123" "007b")
    (mkDevice "router" "1.1" "0101")
    (mkDevice "router-backup" "1.2" "0102")
    (mkDevice "ntpi" "1.123" "017b")
    [
      {
        fqdn = "ecstest.foxden.network";
        ttl = 0;
        type = "LUA TXT";
        value = "bestwho:toString()";
        horizon = "internal";
      }
    ]
  ];
}
