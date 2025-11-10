{ pkgs, ... } :
{
  systemd.user.services.carvera-pendant = {
    unitConfig = {
      Description = "Carvera pendant proxy";
      StartLimitIntervalSec = 0;
      ConditionUser = "appliance";
    };

    serviceConfig = {
      ExecStart = "${pkgs.nodejs_24}/bin/node ./dist/index.js";
      Restart = "always";
      RestartSec = "1s";
      WorkingDirectory = "${pkgs.carvera-pendant}/lib/node_modules/carvera-pendant";

      Environment = [
        "CARVERA_SERIAL_PORT=/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0"
      ];
    };

    after = [ "network.target" ];
    wants = [ "network.target" ];
    wantedBy = [ "default.target" ];
  };
}
