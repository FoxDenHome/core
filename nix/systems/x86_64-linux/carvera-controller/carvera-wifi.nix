{ config, ... }:
{
  sops.secrets.wireless = config.lib.foxDen.sops.mkIfAvailable { };

  networking.wireless = config.lib.foxDen.sops.mkIfAvailable {
    secretsFile = config.sops.secrets.wireless.path;
    networks = {
      FoxDen_Carvera.pskRaw = "ext:psk_carvera";
    };
  };

  networking.networkmanager.enable = false;
}
