{ pkgs, ... } :
{
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="10ce", ATTRS{idProduct}=="eb93", MODE="0660", GROUP="dialout"
    KERNEL=="hidraw*", ATTRS{idVendor}=="10ce", ATTRS{idProduct}=="eb93", MODE="0660", GROUP="dialout"
  '';

  systemd.user.services.carvera-pendant = {
    unitConfig = {
      Description = "Carvera pendant proxy";
      StartLimitIntervalSec = 0;
      ConditionUser = "appliance";
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "1s";
      ExecStart = [ "${pkgs.carvera-pendant}/bin/carvera-pendant" ];

      Environment = [
        "CARVERA_SERIAL_PORT=/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0"
      ];
    };

    after = [ "network.target" ];
    wants = [ "network.target" ];
    wantedBy = [ "default.target" ];
  };
}
