{ config, ... }:
let
  mkCGMNHost =
    cfg:
    config.lib.foxDenSys.mkVlanHost 2001 (
      cfg
      // {
        driver = "bridge";
      }
    );
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
