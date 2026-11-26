{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services.github-runners = config.lib.foxDen.sops.mkIfAvailable {
    conventioncatcorp = {
      enable = true;
      host = "github-runner";
      url = "https://github.com/ConventionCatCorp";
      count = 8;
      runnerGroup = "FoxDen";
      # Service images of ConCat's build.yml
      cachedImages = [
        "gcr.io/concat-cloud/cockroachdb-single-node"
        "valkey/valkey"
      ];
    };
  };

  foxDen.hosts.hosts = {
    github-runner = mkVlanHost 6 {
      dns = {
        fqdns = [ "bengalfox-github-runner.foxden.network" ];
      };
      addresses = [
        "10.6.11.5/16"
        "fd2c:f4cb:63be:6::b05/64"
      ];
    };
  };
}
