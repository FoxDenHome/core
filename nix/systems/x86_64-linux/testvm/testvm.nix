{ modulesPath, pkgs, config, ... }:
let
  ifcfg = {
    addresses = [
      "192.168.122.200/24"
      "fd00:dead:beef:122::200/64"
    ];
    routes = [
      { Destination = "0.0.0.0/0"; Gateway = "192.168.122.1"; }
      { Destination = "::/0"; Gateway = "fd00:dead:beef:122::1"; }
    ];
    nameservers = [ "8.8.8.8" ];
    interface = "br-default";
  };

  rootInterface = "enp1s0";
in
{
  foxDen.sops.available = false;

  system.stateVersion = "25.05";

  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "none";
      fsType = "tmpfs";
      options = [ "mode=755" ];
    };

  fileSystems."/nix" =
    { device = "/dev/vda2";
      fsType = "xfs";
    };

  fileSystems."/boot" =
    { device = "/dev/vda1";
      fsType = "vfat";
      options = [ "fmask=0022" "dmask=0022" ];
    };

  systemd.network.networks."30-${ifcfg.interface}" = {
    name = ifcfg.interface;
    routes = ifcfg.routes;
    address = ifcfg.addresses;
    dns = ifcfg.nameservers;

    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = true;
    };

    # bridgeVLANs = [{
    #   PVID = 2;
    #   EgressUntagged = 2;
    #   VLAN = "1-10";
    # }];
  };

  systemd.network.netdevs."${ifcfg.interface}" = {
    netdevConfig = {
      Name = ifcfg.interface;
      Kind = "bridge";
    };

    bridgeConfig = {
      VLANFiltering = true;
    };
  };

  systemd.network.networks."40-${ifcfg.interface}-${rootInterface}" = {
      name = rootInterface;
      bridge = [ifcfg.interface];
      # bridgeVLANs = [{
      #   PVID = 2;
      #   EgressUntagged = 2;
      #   VLAN = "1-10";
      # }];
  };

  systemd.services."getty@tty1" = {
    overrideStrategy = "asDropin";
    serviceConfig.ExecStart = ["" "@${pkgs.util-linux}/sbin/agetty agetty --login-program ${config.services.getty.loginProgram} --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM"];
  };
}
