{ config, ... }:
let
  wifiIface = "wlp1s0";
in
{
  sops.secrets.wireless = config.lib.foxDen.sops.mkIfAvailable { };

  networking.wireless = config.lib.foxDen.sops.mkIfAvailable {
    enable = false;
    secretsFile = config.sops.secrets.wireless.path;
    networks = {
      FoxDen_Carvera.pskRaw = "ext:psk_carvera";
    };
    extraConfig = "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel";
  };

  networking.networkmanager.enable = false;

  systemd.network.networks."30-${wifiIface}" = {
    name = wifiIface;

    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = false;
    };

    linkConfig = {
      RequiredForOnline = false;
    };
  };
}
