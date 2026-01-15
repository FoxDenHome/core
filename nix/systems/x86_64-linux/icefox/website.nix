{ config, ... }:
let
  mkV6Host = config.lib.foxDenSys.mkV6Host;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    circuitjs = {
      enable = true;
      host = "circuitjs";
      tls = {
        enable = true;
        hsts = "preload";
      };
    };
  };

  foxDen.hosts.hosts = {
    circuitjs = mkV6Host {
      dns = {
        fqdns = [
          "circuitjs.doridian.net"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "2607:5300:60:7065::1:b/112"
        "10.99.12.11/24"
        "fd2c:f4cb:63be::a63:c0b/120"
      ];
    };
  };
}
