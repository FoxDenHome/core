{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.scrypted;
in
{
  options.foxDen.services.scrypted = {
  }
  // (foxDenLib.services.oci.mkOptions {
    svcName = "scrypted";
    name = "Scrypted service";
  });

  config = lib.mkIf svcConfig.enable (
    (foxDenLib.services.oci.make {
      inherit pkgs config svcConfig;
      name = "scrypted";
      gpu = true;
      oci = {
        image = "git.foxden.network/mirror/oci-images/ghcr.io/koush/scrypted:latest";
        volumes = [
          "scrypted_data:/server/volume"
        ];
        environment = {
          "SCRYPTED_DOCKER_AVAHI" = "true";
        };
      };
    }).config
  );
}
