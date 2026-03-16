{
  lib,
  pkgs,
  config,
  ...
}:
let
  greenboostPkgList = [ pkgs.nvidia-greenboost ];
in
{
  options.foxDen.nvidia.enable = lib.mkEnableOption "Enable NVIDIA support";

  config = lib.mkIf config.foxDen.nvidia.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia.open = true;
    hardware.graphics.enable = true;
    hardware.nvidia-container-toolkit.enable = true;

    environment.systemPackages = greenboostPkgList;
    boot.extraModulePackages = greenboostPkgList;
    boot.kernelModules = [ "greenboost" ];
    services.udev.extraRules = ''
      KERNEL=="greenboost", MODE="0666"
    '';

    hardware.graphics.extraPackages = greenboostPkgList ++ pkgs.nvidia-greenboost.libraries;
    foxDen.services.gpu = {
      environment = pkgs.nvidia-greenboost.environment;
      devices = [
        "/dev/greenboost"
        "/dev/nvidiactl"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
        "/dev/nvidia0"
      ];
    };
  };
}
