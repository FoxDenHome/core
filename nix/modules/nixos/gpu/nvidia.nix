{ lib, pkgs, config, ... }:
{
  options.foxDen.nvidia.enable = lib.mkEnableOption "Enable NVIDIA support";

  config = lib.mkIf config.foxDen.nvidia.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia.open = true;
    hardware.graphics.enable = true;
    hardware.nvidia-container-toolkit.enable = true;

    boot.extraModulePackages = [ pkgs.nvidia-greenboost ];
    boot.kernelModules = [ "greenboost" ];
    boot.extraModprobeConfig = ''
      options greenboost nvme_pool_gb=0 nvme_swap_gb=0
    '';
    services.udev.extraRules = ''
      KERNEL=="greenboost", MODE="0666"
    '';

    foxDen.services.gpu.devices = [
      "/dev/greenboost"
      "/dev/nvidiactl"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
      "/dev/nvidia0"
    ];
  };
}
