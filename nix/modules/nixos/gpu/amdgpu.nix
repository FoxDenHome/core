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
    XILINXD_LICENSE_FILE = "/run/amdgpu-data/Xilinx.lic";
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

    systemd.tmpfiles.rules = [
      "d /run/amdgpu-data 0755 root root"
    ];

    sops.secrets."ryzen-ai-license" = config.lib.foxDen.sops.mkIfAvailable { };
    system.activationScripts.reformatRyzenAILicense = config.lib.foxDen.sops.mkIfAvailable {
      text = ''
        ${pkgs.coreutils}/bin/mkdir -p /run/amdgpu-data
        ${pkgs.dos2unix}/bin/unix2dos -n ${
          config.sops.secrets."ryzen-ai-license".path
        } /run/amdgpu-data/Xilinx.lic
      '';
      deps = [
        "setupSecrets"
      ];
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
    foxDen.services.gpu.libraries = [
      "/run/amdgpu-data"
      envVars.XILINX_XRT
    ];
    foxDen.services.gpu.environment = envVars;

    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card1", MODE="0666"
    '';
  };
}
