{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services.foxMail = {
    enable = true;
    host = "foxmail";
    configFromGateway = "icefox";
  };

  foxDen.hosts.hosts = {
    foxmail = mkV6Host {
      dns = {
        fqdns = [ "icefox-foxmail.foxden.network" ];
      };
      addresses = [
        "2607:5300:60:7065::1:d/112"
        "10.99.12.13/24"
        "fd2c:f4cb:63be::a63:c0d/120"
      ];
    };
  };
}
