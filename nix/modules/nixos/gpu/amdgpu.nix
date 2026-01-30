{
  lib,
  config,
  pkgs,
  ...
}:
{
  options.foxDen.amdgpu.enable = lib.mkEnableOption "Enable AMD GPU support";

  config = lib.mkIf config.foxDen.amdgpu.enable {
    services.xserver.videoDrivers = [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = true;
    hardware.graphics.enable = true;
    environment.systemPackages = [
      pkgs.xrt-amdxdna
    ];
    environment.variables.XILINX_XRT = "${pkgs.xrt-amdxdna}/opt/xilinx/xrt";

    boot.kernelModules = [ "amdxdna" ];
    foxDen.services.gpuDevices = [
      "/dev/kfd"
      "/dev/accel/accel0"
      "/dev/dri/card1"
      "/dev/dri/renderD128"
    ];
  };
}
