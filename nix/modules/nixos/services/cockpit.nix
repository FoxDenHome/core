{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf config.services.cockpit.enable {
    services.cockpit = {
      openFirewall = true;
      allowed-origins = [
        "https://*.foxden.network"
        "https://*.foxden.network:9090"
      ];
    };
  };
}
