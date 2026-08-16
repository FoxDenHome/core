{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.foxDen.lsi.enable = lib.mkEnableOption "Enable LSI SAS HBA support";

  config = lib.mkIf config.foxDen.lsi.enable {
    environment.systemPackages = with pkgs; [
      storcli
    ];

    systemd.services.storcli-node-exporter = {
      serviceConfig = {
        Type = "simple";
        User = "root";
        Group = "root";
        ExecStart = [
          "${pkgs.writeShellScript "storcli-node-exporter.sh" ''
            ${pkgs.python}/bin/python3 '${config.foxDen.node-exporter.textfilesContrib}/storcli.py' --storcli-path '${pkgs.storcli}/bin/storcli64' > /var/lib/
          ''}"
        ];
      };
    };

    systemd.timers.storcli-node-exporter = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:*:13";
      };
    };
  };
}
