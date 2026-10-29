{ config, lib, ... }:
{
  # Shared by everything that gets certificates through security.acme
  config.environment.persistence."/nix/persist/foxden/services".directories =
    lib.mkIf (config.security.acme.certs != { })
      [
        {
          directory = "/var/lib/acme";
          user = "acme";
          group = "acme";
          mode = "u=rwx,g=rx,o=rx";
        }
      ];
}
