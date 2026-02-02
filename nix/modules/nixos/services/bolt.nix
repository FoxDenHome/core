{ config, lib, ... }:
{
  config = lib.mkIf config.services.hardware.bolt.enable {
    environment.systemPackages = [ config.services.hardware.bolt.package ];
    environment.persistence."/nix/persist/system".directories = [
      {
        directory = "/var/lib/boltd";
        mode = "u=rwx,g=rx,o=rx";
      }
    ];
  };
}
