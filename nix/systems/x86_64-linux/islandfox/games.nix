{ config, ... }:
let
  mkVlanHost = config.lib.foxDenSys.mkVlanHost;
in
{
  foxDen.services = config.lib.foxDen.sops.mkIfAvailable {
    darksignsonline = {
      enable = true;
      domain = "darksignsonline.com";
      tls = {
        enable = true;
        hsts = "preload";
      };
      host = "darksignsonline";
    };
    minecraft = {
      enable = true;
      tls.enable = true;
      host = "minecraft";
    };
    spaceage-api = {
      enable = true;
      host = "spaceage-api";
      tls = {
        enable = true;
        hsts = "preload";
      };
    };
    spaceage-website = {
      enable = true;
      host = "spaceage-website";
      tls = {
        enable = true;
        hsts = "preload";
      };
    };
    spaceage-tts = {
      enable = true;
      host = "spaceage-tts";
      tls = {
        enable = true;
        hsts = "preload";
      };
    };
    spaceage-gmod = {
      enable = true;
      host = "spaceage-gmod";
    };
  };

  foxDen.hosts.hosts = {
    darksignsonline = mkVlanHost 3 {
      dns = {
        fqdns = [
          "darksignsonline.com"
          "www.darksignsonline.com"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.15/16"
        "fd2c:f4cb:63be:3::a0f/64"
      ];
    };
    minecraft = mkVlanHost 2 {
      dns = {
        fqdns = [
          "minecraft.foxden.network"
          "mc.foxden.network"
        ];
        dynDns = true;
      };
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
        fqdns = [
          "spaceage-gmod.doridian.net"
        ];
        dynDns = true;
      };
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
        fqdns = [
          "spaceage-api.doridian.net"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.5/16"
        "fd2c:f4cb:63be:3::a05/64"
      ];
    };
    spaceage-tts = mkVlanHost 3 {
      dns = {
        fqdns = [
          "spaceage-tts.doridian.net"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.6/16"
        "fd2c:f4cb:63be:3::a06/64"
      ];
    };
    spaceage-website = mkVlanHost 3 {
      dns = {
        fqdns = [
          "spaceage.doridian.net"
        ];
        dynDns = true;
      };
      webservice.enable = true;
      addresses = [
        "10.3.10.9/16"
        "fd2c:f4cb:63be:3::a09/64"
      ];
    };
  };
}
