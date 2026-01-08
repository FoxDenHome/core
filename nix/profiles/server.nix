# Mostly https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/headless.nix
{ lib, config, ... }:
{
  systemd.services."serial-getty@hvc0".enable = false;
  boot.kernelParams = [
    "panic=1"
    "boot.panic_on_fail"
  ];
  systemd.enableEmergencyMode = false;
  boot.initrd.systemd.suppressedUnits = lib.mkIf config.systemd.enableEmergencyMode [
    "emergency.service"
    "emergency.target"
  ];
  boot.loader.grub.splashImage = null;
  documentation.man.enable = false;
}
