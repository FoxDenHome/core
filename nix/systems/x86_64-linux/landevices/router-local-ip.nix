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
    (mkDevice "gateway" "0.1" "0001")
    (mkDevice "dns" "0.53" "0035")
    (mkDevice "ntp" "0.123" "007b")
    (mkDevice "router" "1.1" "0101")
    (mkDevice "router-backup" "1.2" "0102")
    (mkDevice "ntpi" "1.123" "017b")
  ];
}
