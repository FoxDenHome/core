{ ... }:
let
  serverDomain = "arcticfox.doridian.net";
  familyZoneCfg = {
    fastmail = false;
    email = true;
  };
  subCnamesRaw = [
    "ftp"
    "mail"
    "mysql"
    "pop"
    "smtp"
  ];
  subCnames = (map (name: "www.${name}") subCnamesRaw) ++ subCnamesRaw ++ [ "www" ];

  mkFamilyRecords =
    domain:
    (map (name: {
      fqdn = "${name}.${domain}";
      type = "CNAME";
      value = "${domain}.";
      horizon = "*";
    }) subCnames)
    ++ [
      {
        fqdn = domain;
        type = "MX";
        priority = 1;
        ttl = 3600;
        value = "${serverDomain}.";
        horizon = "*";
      }
      {
        fqdn = domain;
        type = "ALIAS";
        ttl = 3600;
        value = "${serverDomain}.";
        horizon = "*";
      }
    ];
in
{
  config.foxDen.dns.zones = {
    "zoofaeth.de" = familyZoneCfg // {
      registrar = "inwx";
    };
    "candy-girl.net" = familyZoneCfg // {
      registrar = "porkbun";
    };
  };

  config.foxDen.dns.records = (mkFamilyRecords "zoofaeth.de") ++ (mkFamilyRecords "candy-girl.net");
}
