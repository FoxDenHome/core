{
  lib,
  config,
  pkgs,
  ...
}:
let
  envVars = {
    XILINX_XRT = "${pkgs.xrt-amdxdna}/opt/xilinx/xrt";
    #XLNX_VART_FIRMWARE = "${pkgs.ryzen-ai-full}/share/xclbin";
    #VAIP_CONFIG = "${pkgs.ryzen-ai-full}/share/vaip/vaip_config.json";
    XILINXD_LICENSE_FILE =
      if config.foxDen.sops.available then config.sops.secrets."ryzen-ai-license".path else "";
  };
in
{
  options.foxDen.amdgpu.enable = lib.mkEnableOption "Enable AMD GPU support";

  config = lib.mkIf config.foxDen.amdgpu.enable {
    environment.systemPackages = with pkgs; [
      rocmPackages.rocm-smi
      xrt-amdxdna
      #ryzen-ai-full
    ];

    sops.secrets."ryzen-ai-license" = config.lib.foxDen.sops.mkIfAvailable {
      mode = "0444";
    };

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
    foxDen.services.gpu.libraries = config.lib.foxDen.sops.mkIfAvailable [
      config.sops.secrets."ryzen-ai-license".path
    ];
    foxDen.services.gpu.environment = envVars;

    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card1", MODE="0666"
    '';
  };
}
