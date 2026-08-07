{ ... }:
let
  dkimPrefix = "arcticfox._domainkey";
  serverDomain = "arcticfox.doridian.net";
  familyZoneCfg = {
    email = "arcticfox";
  };
  subCnamesRaw = [
    "ftp"
    "mail"
    "mysql"
    "pop"
    "smtp"
  ];
  subCnames = (map (name: "www.${name}") subCnamesRaw) ++ subCnamesRaw ++ [ "www" ];

  dkimRecord = {
    "candy-girl.net" =
      "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAljBmbiHNtHgHYBtq1GH9dGL3B/D3OGKtLgJ02I//siiisOV05aqQTq2QpzvhJ3QjyeeAMSLO5jNLfe9CaoUzSfqo6r2CNvy9Eu1e7BmP/TQir+QVaZ5IT0SZ05pIGbs/5C1hGiLEAnHrIeMogLYlq082cxEncc/X3JWpfuca3JrbmgvaSFWpLZg3wKEVO3lEqCN1uhe/XEcTMh9VF+E7yY1GjEtTtLsjfeTX8cQE8Azx1OQjW4xlU+tcqFjMJGGlz5Py6xOA5D4Z5qieOUGh1u9O/6CwjlSrAMHIgs58e2lpomtu5vbyPCU5H0uW7WObp185VahE4snKrrj8Q6lcfwIDAQAB";
    "zoofaeth.de" =
      "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlxpjKvLc5A0fQclpYjkmsWZrofVlShA+P74hJbpyqbn48kYljBoAdPn0tqK6doJQdQQgGvd5VKnbZbhEiLCsGpJ31EBaQHyUM2oYGFnoC8qIeWi4deQhw/HNpI8dhT5Bt2a4bEgL6xhIMRmaeTrXqov67nE2tXiFLoluQqW3K8zcohaHZ1HPMEeSoff8EXSZBQvX+z8ZunGIUtNTypngKNUndvo0A3oraheQJ8zBibz3wBGILor/0w1IhscXceSxkw29vETo1D0Od5POResbGDNoivdazz7OQWtXtclYnG7tfwD/sJP0bjLQqyIfGWFqQbaanty7c/ZqP8Fkl8xM2QIDAQAB";
  };

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
      {
        fqdn = "${dkimPrefix}.${domain}";
        type = "TXT";
        ttl = 3600;
        value = dkimRecord.${domain};
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
