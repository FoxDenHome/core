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
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        inherit pkgs config svcConfig;
        name = "scrypted";
        oci = {
          image = "ghcr.io/koush/scrypted:latest";
          volumes = [
            "scrypted_data:/server/volume"
          ];
          environment = {
            "SCRYPTED_DOCKER_AVAHI" = "true";
          };
        };
      }).config
      {

      }
    ]
  );
}
