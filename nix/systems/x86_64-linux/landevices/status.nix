# The rack dashboard runs as a container on each router (mikrotik/configure/dashboard.py).
# From outside, status.foxden.network reaches router: IPv4 through its foxIngress,
# IPv6 through Ingress PT straight to the container. Inside, the container addresses
# are routed by the client's gateway. Every router gets its own certificate over
# DNS-01, so whichever one answers has a valid certificate.
{ ... }:
let
  fqdn = "status.foxden.network";
  # The dashboard's addresses on the router's container veth, the same on every router
  container = "172.17.2.2";
  container6 = "fd2c:f4cb:63be::ac11:202";
in
{
  config.foxDen.dns.records = [
    # dyndns fills in router's WAN IPv4 and maps container6 into its /60
    {
      inherit fqdn;
      type = "A";
      ttl = 300;
      value = container;
      dynDns = true;
      horizon = "external";
    }
    {
      inherit fqdn;
      type = "AAAA";
      ttl = 300;
      value = container6;
      dynDns = true;
      horizon = "external";
    }
    {
      inherit fqdn;
      type = "A";
      ttl = 3600;
      value = container;
      horizon = "internal";
    }
    {
      inherit fqdn;
      type = "AAAA";
      ttl = 3600;
      value = container6;
      horizon = "internal";
    }
    {
      fqdn = "_acme-challenge.${fqdn}";
      type = "TXT";
      value = "acme";
      ttl = 300; # dns.he.net's minimum
      dynDns = true;
      horizon = "external";
    }
  ];

  config.foxDen.foxIngress = {
    templates.router-dashboard = {
      gateway = "router";
      default.host = container;
      http.port = 80;
      https.port = 443;
    };
    hosts.${fqdn} = {
      gateway = "router";
      template = "router-dashboard";
    };
  };
}
