{ config, ... }:
{
  networking.hosts = {
    "10.99.12.13" = [ "icefox-foxmail.foxden.network" ];
  };
  foxDen.services.foxMail = {
    enable = true;
    host = "foxmail";
    configFromGateway = "icefox";
    senderDomain = "icefox.doridian.net";
  };
  foxDen.hosts.hosts = {
    foxmail =
      let
        host = config.lib.foxDenSys.mkMinHost {
          dns = {
            fqdns = [ "icefox-foxmail.foxden.network" ];
          };
          addresses = [
            "10.99.12.13/24"
            "fd2c:f4cb:63be::a63:c0d/120"
          ];
          sysctls = {
            "net.ipv6.conf.INTERFACE.accept_ra_defrtr" = "0";
          };
        };
      in
      {
        nameservers = host.nameservers;
        interfaces.foxden = host.interfaces.foxden;
      };
  };
}
