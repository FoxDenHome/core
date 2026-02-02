{
  lib,
  config,
  pkgs,
  ...
}:
{
  options.foxDen.amdgpu.enable = lib.mkEnableOption "Enable AMD GPU support";

  config = lib.mkIf config.foxDen.amdgpu.enable {
    environment.systemPackages = with pkgs; [
      rocmPackages.rocm-smi
    ];
    boot.kernelModules = [ "amdxdna" ];
    services.xserver.videoDrivers = [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = true;
    hardware.graphics.enable = true;
    foxDen.services.gpu.devices = [
      "/dev/kfd"
      "/dev/accel/accel0"
      "/dev/dri/card1"
      "/dev/dri/renderD128"
    ];
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card1", MODE="0666"
    '';
  };
}
