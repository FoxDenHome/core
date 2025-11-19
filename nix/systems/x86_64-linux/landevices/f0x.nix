{ ... }:
{
  config.foxDen.dns.records = [
    {
      fqdn = "c0de.f0x.es";
      type = "CNAME";
      ttl = 3600;
      value = "c0defox.es.";
      horizon = "*";
    }
  ];
}
