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
      default = pkgs.fetchFromGitHub {
        owner = "prometheus-community";
        repo = "node-exporter-textfile-collector-scripts";
        rev = "53d484331170e6f00237f0fbd6f4acae33064b87";
        hash = "sha256-mKu61Ds3B/ChmfbEqqFc2ZjBbly3jYCSNZwD3cF5eHg=";
      };
      type = lib.types.package;
    };
    python = lib.mkOption {
      readOnly = true;
      default = pkgs.python3.withPackages (pypkgs: [
        pypkgs.prometheus-client
      ]);
      type = lib.types.package;
    };
    textfileDirectory = lib.mkOption {
      readOnly = true;
      type = lib.types.str;
      default = "/run/node-exporter-textfile";
    };
  };

  config = lib.mkIf config.foxDen.node-exporter.enable {
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [
        "systemd"
        "textfile"
      ];
      extraFlags = [ "--collector.textfile.directory=/run/node-exporter-textfile" ];
    };

    systemd.tmpfiles.rules = [
      "d /run/node-exporter-textfile 0755 root root"
    ];
  };
}
