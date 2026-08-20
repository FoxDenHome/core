{ config, lib, ... }:
let
  yes = lib.kernel.yes;
in
{
  options.foxDen.mlx5.enable = lib.mkEnableOption "Enable full MLX5 kernel support";

  config = lib.mkIf config.foxDen.mlx5.enable {
    boot.kernelPatches = [
      {
        name = "mlx5-en-tls";
        patch = null;
        structuredExtraConfig = {
          MLX5_FPGA = yes;
          MLX5_EN_TLS = yes;
          MLX5_CORE_IPOIB = yes;
          MLX5_MACSEC = yes;
          MLX5_EN_IPSEC = yes;
        };
      }
    ];
  };
}
