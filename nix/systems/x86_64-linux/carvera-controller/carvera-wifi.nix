{ config, ... }:
{
  sops.secrets.wireless = config.lib.foxDen.sops.mkIfAvailable { };

  networking.wireless = config.lib.foxDen.sops.mkIfAvailable {
    enable = true;
    secretsFile = config.sops.secrets.wireless.path;
    networks = {
      FoxDen_Carvera.pskRaw = "ext:psk_carvera";
    };
    extraConfig = "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel";
  };

  networking.networkmanager.enable = false;
}
