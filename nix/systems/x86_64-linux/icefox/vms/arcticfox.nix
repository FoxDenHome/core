{ ... }:
{
  foxDen.vms.arcticfox = {
    host = "arcticfox";
    rootDiskSize = "128G";
    hardware = {
      uuid = "fd300e9a-1168-4b12-b4e6-7cded421a9d3";
      memory = "8G";
      smp = "8,sockets=1,dies=1,clusters=1,cores=4,threads=2";
      cpuAffinity = "4-7 12-15";
      # Guest core N (threads 2N, 2N+1) on host core 4+N and its sibling
      vcpuPinning = [
        4
        12
        5
        13
        6
        14
        7
        15
      ];
      network.default = {
        type = "sriov";
        root = "eno1np0";
        vf = 63;
      };
      shares = [
        {
          tag = "backup";
          source = "/mnt/ztank/local/backups/arcticfox";
        }
      ];
    };
  };

  foxDen.hosts.hosts.arcticfox = {
    ssh = true;
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
        "2607:5300:60:7065::ff01/64"
      ];
      mac = "02:00:00:6d:d5:fc";
    };
  };

  foxDen.dns.records = [
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
