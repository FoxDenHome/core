{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    kanidm.server = {
      enable = true;
      tls.enable = true;
      host = "auth";
    };
    oauth-jit-radius = {
      enable = true;
      host = "radius-auth";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "radius";
        displayName = "JIT RADIUS";
        imageFile = ../../../files/icons/radius.svg;
      };
    };
    vpn-portal = {
      enable = true;
      host = "portal";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "portal";
        displayName = "FoxDen portal";
      };
    };
    kerberos = {
      enable = true;
      host = "kerberos";
      tls.enable = true;
      oAuth = {
        enable = true;
        clientId = "krb5-sync";
        displayName = "Kerberos Sync";
      };
    };
  };

  foxDen.hosts.hosts = {
    auth = mkVlanHost 2 {
      dns = {
        fqdns = [ "auth.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.24/16"
        "fd2c:f4cb:63be:2::b18/64"
      ];
    };
    radius-auth = mkVlanHost 2 {
      dns = {
        fqdns = [ "radius.auth.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      firewall.ingressAcceptRules = [
        {
          source = "10.1.0.0/16";
          comment = "trusted-mgmt-radius-auth";
          port = 1812;
          protocol = "udp";
        }
        {
          source = "fd2c:f4cb:63be:1::/64";
          comment = "trusted-mgmt-radius-auth";
          port = 1812;
          protocol = "udp";
        }
      ];
      addresses = [
        "10.2.11.11/16"
        "fd2c:f4cb:63be:2::b0b/64"
      ];
    };
    portal = mkVlanHost 2 {
      dns = {
        fqdns = [ "portal.foxden.network" ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.40/16"
        "fd2c:f4cb:63be:2::b28/64"
      ];
    };
    kerberos = mkVlanHost 2 {
      dns = {
        fqdns = [ "kerberos.foxden.network" ];
        # Public records for ACME; only the web UI is reachable from outside.
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.2.11.41/16"
        "fd2c:f4cb:63be:2::b29/64"
      ];
    };
  };
}
