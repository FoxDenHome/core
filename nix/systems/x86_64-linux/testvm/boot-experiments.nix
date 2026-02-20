{ config, lib, pkgs, ... }:
let
  uki = "${config.system.build.uki}/nixos.efi";
  espMounts = [
    "/boot"
  ];
in
{
    system.activationScripts.installFoxDenUki = {
      text = lib.concatStringsSep "\n" (map (esp: ''
        ${pkgs.coreutils}/bin/mkdir -p ${esp}/EFI_/BOOT
        ${pkgs.coreutils}/bin/cp ${uki} ${esp}/EFI_/BOOT/BOOTX64.EFI
      '') espMounts);
    };
}
