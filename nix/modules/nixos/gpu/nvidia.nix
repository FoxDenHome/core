{
  lib,
  pkgs,
  config,
  ...
}:
let
  greenboostShim = "${pkgs.nvidia-greenboost}/lib/libgreenboost_cuda.so";
in
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
      libraries = [
        greenboostShim
        "${pkgs.glibc.out}"
      ];
      environment.LD_PRELOAD = greenboostShim;
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
