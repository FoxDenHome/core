{ ... }:
let
  dkimPrefixes = ["foxmail._domainkey" "foxmail-backup._domainkey"];
  domains = [
    "doridian.net"
    "doridian.de"
    "foxden.network"
    "f0x.es"
    "foxcav.es"
    "darksignsonline.com"
  ];
in
{
  config.foxDen.dns.records = [
    # {
    #   fqdn = "${dkimPrefix}.doridian.net";
    #   type = "TXT";
    #   ttl = 3600;
    #   value = "v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3f9m7AcniGGUN+1XjLO65/vnMsj9gPqL8VpAZTNn8yshIB8pgOau599Z+a8u6OEUyNdoEiGGXhQ+cbaheZ73itCiyhpcMsr4vW862WzZxEqKk/19a8AK1956PhNUMATJ51I7xBI+2ktswwW8dZq5NXvB7Yobah3H+cyVWpJLyZsIt+P0U7+oNRsXUeLeRxBmkRZjGhnsrWx6DlU4sTg1o97sZ2nbTX6Nzi+UxG9abXUfdfcvkgpWbXjpI+EuPeaIHJ8+HFuVKzsWEA4Fajfq0Et2ROjVyzoqX7ndxLOaSHzLFXPqYo2OrDHoPrk1NQ6wLRLojrxfginoHebuSaSuUQIDAQAB";
    #   horizon = "*";
    # }
  ];
}
