{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.foxDen.amdgpu;

  envVars = {
    #XILINX_XRT = "${pkgs.xrt-amdxdna}/opt/xilinx/xrt";
    #XLNX_VART_FIRMWARE = "${pkgs.ryzen-ai-full}/share/xclbin";
    #VAIP_CONFIG = "${pkgs.ryzen-ai-full}/share/vaip/vaip_config.json";
    XILINXD_LICENSE_FILE = "/run/amdgpu-data/Xilinx.lic";
  }
  // lib.optionalAttrs (cfg.hsaOverrideGfxVersion != null) {
    HSA_OVERRIDE_GFX_VERSION = cfg.hsaOverrideGfxVersion;
  };
in
{
  options.foxDen.amdgpu = {
    enable = lib.mkEnableOption "Enable AMD GPU support";
    hsaOverrideGfxVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "11.0.0";
      description = "Make ROCm treat the GPU as this gfx version, for GPUs ROCm does not officially support";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      rocmPackages.amdsmi
      rocmPackages.rocm-smi
    ];

    systemd.tmpfiles.rules = [
      "d /run/amdgpu-data 0755 root root"
    ];

    boot.kernelModules = [ "amdxdna" ];
    services.xserver.videoDrivers = [ "amdgpu" ];
    hardware.amdgpu.opencl.enable = true;
    hardware.graphics.enable = true;
    environment.variables = envVars;

    foxDen.services.gpu = {
      devices = [
        "/dev/kfd"
        "/dev/accel/accel0"
        "/dev/dri/card1"
        "/dev/dri/renderD128"
      ];
      paths = [
        "/run/amdgpu-data"
      ];
      environment = envVars;
    };

    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card1", MODE="0666"
    '';
  };
}
