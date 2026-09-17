{
  config,
  pkgs,
  lib,
  ...
}:
let
  yes = lib.kernel.yes;
  ethtool = "${pkgs.ethtool}/bin/ethtool";
in
{
  options.foxDen.mlx5.enable = lib.mkEnableOption "Enable full MLX5 kernel support";

  config = lib.mkMerge [
    {
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="net", ID_NET_DRIVER=="mlx5_core", \
          RUN+="${ethtool} --set-priv-flags $name rx_cqe_compress off", \
          RUN+="${ethtool} -K $name rxhash on"
      '';
    }
    (lib.mkIf config.foxDen.mlx5.enable {
      boot.kernelModules = [
        "mlx5_core"
        "mlx5_en"
        "rdma_cm"
      ];
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
    })
  ];
}
