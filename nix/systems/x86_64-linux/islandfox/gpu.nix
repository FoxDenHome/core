{ ... }:
{
  services.xserver.videoDrivers = [ "amdgpu" ];

  hardware.amdgpu.opencl.enable = true;
  hardware.graphics.enable = true;

  foxDen.services.gpuDevices = [
    "/dev/kfd"
    "/dev/accel/accel0"
    "/dev/dri/card1"
    "/dev/dri/renderD128"
  ];
}
