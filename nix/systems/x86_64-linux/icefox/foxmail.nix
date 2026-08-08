{ ... }:
{
  foxDen.services.foxMail = {
    enable = true;
    host = "";
    configFromGateway = "icefox";
  };
  networking.firewall.interfaces = {
    br-foxden.allowedTCPPorts = [
      9002
      2525
    ];
    wg-foxden.allowedTCPPorts = [
      9002
      2525
    ];
  };
}
