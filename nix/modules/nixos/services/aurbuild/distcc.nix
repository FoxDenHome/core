{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.aurbuild-distcc;
in
{
  options.foxDen.services.aurbuild-distcc = foxDenLib.services.oci.mkOptions {
    svcName = "aurbuild-distcc";
    name = "AUR build distcc service";
  };

  config = lib.mkIf svcConfig.enable (
    (foxDenLib.services.oci.make {
      inherit pkgs config svcConfig;
      name = "aurbuild-distcc";
      oci = {
        image = "git.foxden.network/foxdenaur/builder:distcc";
        volumes = [
          "${./packages.txt}:/aur/packages.txt:ro"
          "${./makepkg.conf}:/etc/makepkg.conf:ro"
          "aurbuild_cache:/aur/cache"
        ];
        extraOptions = [
          "--mount=type=tmpfs,tmpfs-size=128M,destination=/aur/tmp"
        ];
      };
      systemd.serviceConfig.Nice = 6;
    }).config
  );
}
