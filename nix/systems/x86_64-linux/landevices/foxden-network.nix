{ ... }:
{
  config.foxDen.dns.zones = {
    "foxden.network" = {
      authority = "foxden-network";
    };
  };

  config.foxDen.dns.authorities = {
    foxden-network = {
      admin = "admin@cloudns.net";
      nameservers = [
        "pns41.cloudns.net."
        "pns42.cloudns.net."
        "pns43.cloudns.net."
        "pns44.cloudns.net."
      ];
    };
  };
}
