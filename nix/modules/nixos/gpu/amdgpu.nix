{
  lib,
  config,
  pkgs,
  ...
}:
let
  xrt_path = "${pkgs.xrt-amdxdna}/opt/xilinx/xrt";
in
{
  options.foxDen.amdgpu.enable = lib.mkEnableOption "Enable AMD GPU support";

  config = lib.mkIf config.foxDen.amdgpu.enable {
    boot.kernelModules = [ "amdxdna" ];
    services.xserver.videoDrivers = [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = true;
    hardware.graphics.enable = true;
    environment.systemPackages = [
      pkgs.xrt-amdxdna
    ];
    environment.variables.XILINX_XRT = xrt_path;

    foxDen.services.gpu.libraries = [
      xrt_path
    ];
    foxDen.services.gpu.devices = [
      "/dev/kfd"
      "/dev/accel/accel0"
      "/dev/dri/card1"
      "/dev/dri/renderD128"
    ];
    foxDen.services.gpu.environment.XILINX_XRT = xrt_path;
  };
}
