{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.foxDen.node-exporter = {
    enable = lib.mkEnableOption "Enable Prometheus node-exporter";
    textfilesContrib = lib.mkOption {
      readOnly = true;
      default = pkgs.fetchFromGithub {
        owner = "prometheus-community";
        repo = "node-exporter-textfile-collector-scripts";
        rev = "53d484331170e6f00237f0fbd6f4acae33064b87";
      };
      type = lib.types.package;
    };
  };

  config = lib.mkIf config.foxDen.node-exporter.enable {
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [
        "systemd"
        "textfile"
      ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/node-exporter/textfile" ];
    };
  };
}
