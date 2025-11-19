{
  rootDiskSize = "128G";
  autostart = true;
  interfaces.default = {
    dns = {
      fqdn = "arcticfox.doridian.net";
    };
    cnames = [
      {
        fqdn = "pma.arcticfox.doridian.net";
      }
      {
        fqdn = "ftp.arcticfox.doridian.net";
      }
      {
        fqdn = "mail.arcticfox.doridian.net";
      }
      {
        fqdn = "www.pma.arcticfox.doridian.net";
      }
      {
        fqdn = "www.ftp.arcticfox.doridian.net";
      }
      {
        fqdn = "www.mail.arcticfox.doridian.net";
      }
    ];
    addresses = [
      "95.216.116.135/26"
      "2a01:4f9:2b:1a42::ff01/112"
    ];
    mac = "00:50:56:00:D8:C7";
  };
  records = [
    {
      fqdn = "arcticfox.doridian.net";
      type = "TXT";
      ttl = 3600;
      value = "v=spf1 +a:arcticfox.doridian.net include:amazonses.com mx ~all";
      horizon = "*";
    }
    {
      fqdn = "_dmarc.arcticfox.doridian.net";
      type = "TXT";
      ttl = 3600;
      value = "v=DMARC1;p=quarantine;pct=100";
      horizon = "*";
    }
    {
      fqdn = "arcticfox.doridian.net";
      type = "A";
      ttl = 3600;
      value = "95.216.116.135";
      horizon = "internal";
    }
    {
      fqdn = "arcticfox.doridian.net";
      type = "AAAA";
      ttl = 3600;
      value = "2a01:4f9:2b:1a42::ff01";
      horizon = "internal";
    }
    {
      fqdn = "www.arcticfox.doridian.net";
      type = "CNAME";
      ttl = 3600;
      value = "arcticfox.doridian.net.";
      horizon = "*";
    }
  ];
}
