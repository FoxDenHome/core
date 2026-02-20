{
  config,
  lib,
  pkgs,
  ...
}:
let
  uki = config.system.boot.loader.ukiFile;
  espMounts = [
    "/boot"
  ];
in
{
  boot.loader = {
    systemd-boot.enable = lib.mkForce false;
    grub.enable = false;
    external = {
      enable = true;
      installHook = pkgs.writeShellScript "foxden-esp" (
        lib.concatStringsSep "\n" (
          map (esp: ''
            ${pkgs.coreutils}/bin/mkdir -p ${esp}/EFI_/BOOT
            ${pkgs.coreutils}/bin/cp ${uki} ${esp}/EFI_/BOOT/BOOTX64.EFI
          '') espMounts
        )
      );
    };
  };
}
