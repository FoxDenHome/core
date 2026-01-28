{ ... }:
{
  services.xserver.videoDrivers = [ "amdgpu" ];

  hardware.amdgpu.opencl.enable = true;
  hardware.graphics.enable = true;

  foxDen.services.gpuDevices = [
    "/dev/dri/renderD128"
  ];
}
