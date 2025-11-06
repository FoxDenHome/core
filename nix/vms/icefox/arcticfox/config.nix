{
  rootDiskSize = "128G";
  autostart = true;
  interfaces.default = {
    dns = {
      name = "arcticfox.doridian.net";
    };
    cnames = [
      {
        name = "pma.arcticfox.doridian.net";
      }
      {
        name = "ftp.arcticfox.doridian.net";
      }
      {
        name = "mail.arcticfox.doridian.net";
      }
      {
        name = "www.pma.arcticfox.doridian.net";
      }
      {
        name = "www.ftp.arcticfox.doridian.net";
      }
      {
        name = "www.mail.arcticfox.doridian.net";
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
      name = "arcticfox.doridian.net";
      type = "TXT";
      ttl = 3600;
      value = "v=spf1 +a:arcticfox.doridian.net include:amazonses.com mx ~all";
      horizon = "*";
    }
    {
      name = "_dmarc.arcticfox.doridian.net";
      type = "TXT";
      ttl = 3600;
      value = "v=DMARC1;p=quarantine;pct=100";
      horizon = "*";
    }
    {
      name = "arcticfox.doridian.net";
      type = "A";
      ttl = 3600;
      value = "95.216.116.135";
      horizon = "internal";
    }
    {
      name = "arcticfox.doridian.net";
      type = "AAAA";
      ttl = 3600;
      value = "2a01:4f9:2b:1a42::ff01";
      horizon = "internal";
    }
    {
      name = "www.arcticfox.doridian.net";
      type = "CNAME";
      ttl = 3600;
      value = "arcticfox.doridian.net.";
      horizon = "*";
    }
  ];
}
