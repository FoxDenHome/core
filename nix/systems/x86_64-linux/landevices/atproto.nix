{ ... }:
{
  config.foxDen.dns.records = [
    {
      fqdn = "_atproto.doridian.net";
      type = "TXT";
      ttl = 3600;
      value = "did=did:plc:imzcu3nra2hq3ibksykj7i6x";
      horizon = "*";
    }
  ];
}
