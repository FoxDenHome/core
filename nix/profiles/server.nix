# Mostly https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/headless.nix
{
  lib,
  config,
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

  hardware.rasdaemon.enable = true;

  documentation = {
    man.enable = false;
    info.enable = false;
    doc.enable = false;
    nixos.enable = false;
  };

  foxDen.deploy.push.enable = true;

  services.cockpit.enable = false; # TODO: Currently mostly broken, at least the important bits (storage + libvirt)

  environment.persistence."/nix/persist/system" = {
    directories = [ "/var/lib/rasdaemon" ];
  };

  boot.extraModprobeConfig = ''
    options ib_core netns_mode=0
  '';

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" ];
  };
  networking.firewall.extraInputRules = ''
    ip saddr 10.0.0.0/8 tcp dport ${toString config.services.prometheus.exporters.node.port} accept
    ip6 saddr fc00::/7 tcp dport ${toString config.services.prometheus.exporters.node.port} accept
  '';
}
