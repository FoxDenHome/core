{
  rootDiskSize = "128G";
  autostart = true;
  interfaces.default = {
    dns = {
      fqdns = [
        "arcticfox.doridian.net"
        "pma.arcticfox.doridian.net"
        "ftp.arcticfox.doridian.net"
        "mail.arcticfox.doridian.net"
        "www.arcticfox.doridian.net"
        "www.pma.arcticfox.doridian.net"
        "www.ftp.arcticfox.doridian.net"
        "www.mail.arcticfox.doridian.net"
      ];
    };
    addresses = [
      "51.79.107.29/32"
      "2607:5300:60:7065::ff01/112"
    ];
    mac = "02:00:00:6d:d5:fc";
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
      value = "51.79.107.29";
      horizon = "internal";
    }
    {
      fqdn = "arcticfox.doridian.net";
      type = "AAAA";
      ttl = 3600;
      value = "2607:5300:60:7065::ff01";
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
