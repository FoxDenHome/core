{ ... }:
{
  networking.hosts = {
    "10.99.12.1" = [ "icefox.foxden.network" ];
  };
  foxDen.services.foxMail = {
    enable = true;
    host = "";
    configFromGateway = "icefox";
  };
}
