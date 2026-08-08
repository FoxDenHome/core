{ ... }:
{
  foxDen.services.foxMail = {
    enable = true;
    host = "";
    configFromGateway = "icefox";
  };
  foxDen.hosts.hosts.icefox.interface.foxden = {
    firewall.ingressAcceptRules = [
      {
        protocol = "tcp";
        port = 2525;
      }
    ];
  };
}
