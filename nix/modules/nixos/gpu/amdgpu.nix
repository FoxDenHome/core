{
  lib,
  config,
  pkgs,
  ...
}:
let
  envVars.XILINX_XRT = "${pkgs.xrt-amdxdna}/opt/xilinx/xrt";
in
{
  options.foxDen.amdgpu.enable = lib.mkEnableOption "Enable AMD GPU support";

  config = lib.mkIf config.foxDen.amdgpu.enable {
    environment.systemPackages = with pkgs; [
      rocmPackages.rocm-smi
      xrt-amdxdna
    ];
    boot.kernelModules = [ "amdxdna" ];
    services.xserver.videoDrivers = [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = true;
    hardware.graphics.enable = true;
    environment.variables = envVars;

    foxDen.services.gpu.devices = [
      "/dev/kfd"
      "/dev/accel/accel0"
      "/dev/dri/card1"
      "/dev/dri/renderD128"
    ];
    foxDen.services.gpu.environment = envVars;

    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card1", MODE="0666"
    '';
  };
}
