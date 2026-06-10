{ lib, ... }:
let
  mkDevice = name: suffix4: suffix6: [
    {
      fqdn = "${name}.foxden.network";
      ttl = 30;
      type = "A";
      value = "10.2.${suffix4}";
      horizon = "internal";
    }
    {
      fqdn = "${name}.foxden.network";
      ttl = 30;
      type = "AAAA";
      value = "fd2c:f4cb:63be:2::${suffix6}";
      horizon = "internal";
    }
  ];
in
{
  config.foxDen.dns.records = lib.flatten [
    (mkDevice "gateway" "0.1" "1")
    (mkDevice "dns" "0.53" "35")
    (mkDevice "ntp" "0.123" "7b")
    (mkDevice "router" "1.1" "101")
    (mkDevice "router-backup" "1.2" "102")
    (mkDevice "ntpi" "1.123" "17b")
  ];
}
