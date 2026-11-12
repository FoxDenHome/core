{ config, lib, ... }:
{
  # Shared by everything that gets certificates through security.acme
  config = lib.mkIf (config.security.acme.certs != { }) {
    security.acme.defaults.dnsResolver = [
      "8.8.8.8:53"
      "8.8.4.4:53"
      "1.1.1.1:53"
      "1.0.0.1:53"
    ];
    environment.persistence."/nix/persist/foxden/services".directories = [
      {
        directory = "/var/lib/acme";
        user = "acme";
        group = "acme";
        mode = "u=rwx,g=rx,o=rx";
      }
    ];
  };
}
