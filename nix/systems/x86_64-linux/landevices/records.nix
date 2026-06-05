{ ... }:
{
  config.foxDen.dns.records = [
    {
      fqdn = "ping.foxden.network";
      type = "CNAME";
      ttl = 3600;
      horizon = "*";
      value = "d6r13h26jmbo9.cloudfront.net";
    }
    {
      fqdn = "_cc1e27bef854372b85ecef3e0f3435b9.ping.foxden.network";
      type = "CNAME";
      ttl = 3600;
      horizon = "*";
      value = "_c23c009d2d132007f92b588d1784c21f.jkddzztszm.acm-validations.aws";
    }
  ];
}
