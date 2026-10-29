{ ... }:
{
  foxDen.deviceCerts = {
    enable = true;
    devices = {
      ups-rack = {
        type = "eaton";
        address = "10.1.11.2";
      };
      ups-dori-office = {
        type = "cyberpower";
        address = "10.1.11.3";
      };
      ats-rack = {
        type = "cyberpower";
        address = "10.1.11.4";
      };
    };
  };
}
