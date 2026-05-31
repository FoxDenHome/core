{ ... }:
{
  config = {
    services.pcscd.enable = true;
    systemd.services.pcscd.serviceConfig = {
      PrivateUsers = "full";
    };
  };
}
