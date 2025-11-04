{ ... }:
let
  rootServer = "arcticfox.doridian.net.";

  subCnamesRaw = [
    "ftp"
    "mail"
    "mysql"
    "pop"
    "smtp"
  ];
  subCnames = (map (name: "www.${name}") subCnamesRaw) ++ subCnamesRaw ++ ["www"];

  mkFamilyRecords = domain: (map (name: {
    name = "${name}.${domain}";
    type = "CNAME";
    value = "@" ;
    horizon = "*";
  }) subCnames) ++ [
    {
      name = domain;
      type = "MX";
      priority = 1;
      ttl = 3600;
      value = rootServer;
      horizon = "*";
    }
    {
      name = domain;
      type = "ALIAS";
      ttl = 3600;
      value = rootServer;
      horizon = "*";
    }
  ];
in
{
  config.foxDen.dns.zones = {
    "zoofaeth.de" = {
      registrar = "inwx";
      fastmail = false;
      ses = true;
      nameservers = "default";
    };
    "candy-girl.net" = {
      registrar = "inwx";
      fastmail = false;
      ses = true;
      nameservers = "default";
    };
  };

  config.foxDen.dns.records = 
    (mkFamilyRecords "zoofaeth.de")
    ++ (mkFamilyRecords "candy-girl.net");
}
