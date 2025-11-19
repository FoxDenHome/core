{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    grafana = {
      enable = true;
      host = "grafana";
      tls = true;
      oAuth = {
        enable = true;
        clientId = "grafana";
        displayName = "Grafana";
        imageFile = ../../../files/icons/grafana.svg;
      };
    };
    mktxp = {
      enable = true;
      host = "mktxp";
    };
    prometheus = {
      enable = true;
      host = "prometheus";
    };
    telegraf = {
      enable = true;
      host = "telegraf";
    };
  };

  foxDen.hosts.hosts = {
    grafana = mkVlanHost 2 {
      dns = {
        fqdns = [ "grafana.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.5/16"
        "fd2c:f4cb:63be:2::b05/64"
      ];
    };
    prometheus = mkVlanHost 2 {
      dns = {
        fqdns = [ "prometheus.foxden.network" ];
      };
      addresses = [
        "10.2.11.20/16"
        "fd2c:f4cb:63be:2::b14/64"
      ];
    };
    telegraf = mkVlanHost 2 {
      dns = {
        fqdns = [ "telegraf.foxden.network" ];
      };
      addresses = [
        "10.2.11.21/16"
        "fd2c:f4cb:63be:2::b15/64"
      ];
    };
    mktxp = mkVlanHost 2 {
      dns = {
        fqdns = [ "mktxp.foxden.network" ];
      };
      addresses = [
        "10.2.11.22/16"
        "fd2c:f4cb:63be:2::b16/64"
      ];
    };
  };
}
