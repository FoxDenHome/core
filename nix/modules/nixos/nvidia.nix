{ lib, config, ... }:
{
  options.foxDen.nvidia.enable = lib.mkEnableOption "Enable NVIDIA support via the proprietary drivers";

  config = lib.mkIf config.foxDen.nvidia.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia.open = true;
    hardware.graphics.enable = true;
    hardware.nvidia-container-toolkit.enable = true;

    foxDen.services.gpuDevices = [
      "/dev/nvidiactl"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
      "/dev/nvidia0"
    ];
  };
}
