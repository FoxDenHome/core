{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    darksignsonline = {
      enable = true;
      domain = "darksignsonline.com";
      tls = true;
      host = "darksignsonline";
    };
    minecraft = {
      enable = true;
      tls = true;
      host = "minecraft";
    };
    spaceage-api = {
      enable = true;
      host = "spaceage-api";
      tls = true;
    };
    spaceage-website = {
      enable = true;
      host = "spaceage-website";
      tls = true;
    };
    spaceage-tts = {
      enable = true;
      host = "spaceage-tts";
      tls = true;
    };
    spaceage-gmod = {
      enable = true;
      host = "spaceage-gmod";
    };
  };

  foxDen.hosts.hosts = {
    darksignsonline = mkVlanHost 3 {
      dns = {
        fqdn = "darksignsonline.com";
        dynDns = true;
      };
      cnames = [
        {
          fqdn = "www.darksignsonline.com";
        }
      ];
      webservice.enable = true;
      addresses = [
        "10.3.10.15/16"
        "fd2c:f4cb:63be:3::a0f/64"
      ];
    };
    minecraft = mkVlanHost 2 {
      dns = {
        fqdn = "minecraft.foxden.network";
        dynDns = true;
      };
      cnames = [
        {
          fqdn = "mc.foxden.network";
        }
        {
          fqdn = "mc.doridian.net";
        }
      ];
      webservice.enable = true;
      firewall.portForwards = [
        {
          protocol = "tcp";
          port = 25565;
        }
      ];
      addresses = [
        "10.2.11.14/16"
        "fd2c:f4cb:63be:2::b0e/64"
      ];
    };
    spaceage-gmod = mkVlanHost 3 {
      dns = {
        fqdn = "spaceage-gmod.foxden.network";
        dynDns = true;
      };
      cnames = [
        {
          fqdn = "gmod.spaceage.mp";
        }
        {
          fqdn = "play.spaceage.mp";
        }
      ];
      firewall.portForwards = [
        {
          protocol = "udp";
          port = 27015;
        }
      ];
      addresses = [
        "10.3.10.4/16"
        "fd2c:f4cb:63be:3::a04/64"
      ];
    };
    spaceage-api = mkVlanHost 3 {
      dns = {
        fqdn = "spaceage-api.foxden.network";
        dynDns = true;
      };
      webservice.enable = true;
      cnames = [
        {
          fqdn = "api.spaceage.mp";
        }
      ];
      addresses = [
        "10.3.10.5/16"
        "fd2c:f4cb:63be:3::a05/64"
      ];
    };
    spaceage-tts = mkVlanHost 3 {
      dns = {
        fqdn = "spaceage-tts.foxden.network";
        dynDns = true;
      };
      webservice.enable = true;
      cnames = [
        {
          fqdn = "tts.spaceage.mp";
        }
      ];
      addresses = [
        "10.3.10.6/16"
        "fd2c:f4cb:63be:3::a06/64"
      ];
    };
    spaceage-website = mkVlanHost 3 {
      dns = {
        fqdn = "spaceage.mp";
        dynDns = true;
      };
      webservice.enable = true;
      cnames = [
        {
          fqdn = "www.spaceage.mp";
        }
      ];
      addresses = [
        "10.3.10.9/16"
        "fd2c:f4cb:63be:3::a09/64"
      ];
    };
  };
}
