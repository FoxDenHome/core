{ config, ... }:
let
  mkCGMNHost =
    cfg:
    (config.lib.foxDenSys.mkVlanHost 2001 (
      cfg
      // {
        driver.name = "bridge";
        routes = [
          {
            Destination = "0.0.0.0/0";
            Gateway = "100.68.41.1";
          }
        ];
      }
    ))
    // {
      nameservers = [ "100.68.41.1" ];
    };
in
{
  foxDen.services = {
    cghmn-squidcache = {
      enable = true;
      host = "cghmn-squidcache";
    };
  };

  foxDen.hosts.hosts = {
    cghmn-squidcache = mkCGMNHost {
      dns = {
        fqdns = [ "cghmn-squidcache.foxden.network" ];
      };
      addresses = [ "100.68.41.2/16" ];
    };
  };
}
