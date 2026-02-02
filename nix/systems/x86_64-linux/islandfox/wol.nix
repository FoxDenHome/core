{ pkgs, ... }:
let
  wolIface = "enp2s0";
in
{
  networking.firewall = {
    allowedUDPPorts = [ 9 ];
  };
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", NAME=="${wolIface}", RUN+="${pkgs.ethtool}/bin/ethtool -s ${wolIface} wol g"
  '';

  systemd.network.networks."30-${wolIface}" = {
    name = wolIface;

    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
    };
  };
}
