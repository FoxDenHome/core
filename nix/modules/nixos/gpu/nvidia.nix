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
    services.udev.extraRules = ''
      KERNEL=="greenboost", MODE="0666"
    '';

    foxDen.services.gpu = {
      libraries = [ pkgs.nvidia-greenboost ];
      environment.LD_PRELOAD = "${pkgs.nvidia-greenboost}/lib/libgreenboost_cuda.so";
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
