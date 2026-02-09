# Mostly https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/headless.nix
{
  lib,
  config,
  pkgs,
  ...
}:
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

  networking.firewall = {
    allowedUDPPorts = [ config.services.iperf3.port ];
    allowedTCPPorts = [ config.services.iperf3.port ];
  };
  services.iperf3.enable = true;
  environment.systemPackages = with pkgs; [
    iperf
  ];

  hardware.rasdaemon.enable = true;

  documentation = {
    man.enable = false;
    info.enable = false;
    doc.enable = false;
    nixos.enable = false;
  };

  foxDen.deploy.push.enable = true;

  environment.persistence."/nix/persist/system" = {
    directories = [
      {
        directory = "/var/lib/rasdaemon";
      }
    ];
  };

  boot.extraModprobeConfig = ''
    options ib_core netns_mode=0
  '';
}
