{ lib, config, ... }:
{
  options.foxDen.amdgpu.enable = lib.mkEnableOption "Enable AMD GPU support";

  config = lib.mkIf config.foxDen.amdgpu.enable {
    services.xserver.videoDrivers = [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = true;
    hardware.graphics.enable = true;

    foxDen.services.gpuDevices = [
      "/dev/kfd"
      "/dev/accel/accel0"
      "/dev/dri/card1"
      "/dev/dri/renderD128"
    ];
  };
}
