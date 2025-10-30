{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    e621dumper = {
      enable = true;
      dataDir = "/mnt/zhdd/e621";
      host = "e621dumper";
      tls = true;
      oAuth = {
        enable = true;
        displayName = "e621Dumper";
        clientId = "e621dumper";
        bypassInternal = true;
      };
    };
    fadumper = {
      enable = true;
      dataDir = "/mnt/zhdd/furaffinity";
      host = "fadumper";
      tls = true;
      oAuth = {
        enable = true;
        displayName = "FADumper";
        clientId = "fadumper";
        bypassInternal = true;
      };
    };
  };

  foxDen.hosts.hosts = {
    e621dumper = mkVlanHost 2 {
      dns = {
        name = "e621.foxden.network";
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.18/16"
        "fd2c:f4cb:63be:2::b12/64"
      ];
    };
    fadumper = mkVlanHost 2 {
      dns = {
        name = "furaffinity.foxden.network";
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.19/16"
        "fd2c:f4cb:63be:2::b13/64"
      ];
    };
  };
}
