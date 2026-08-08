{ ... }:
{
  foxDen.services.foxMail = {
    enable = true;
    host = "";
    configFromGateway = "icefox";
  };
  networking.interfaces."br-foxden".allowedTCPPorts = [ 2525 ];
}
