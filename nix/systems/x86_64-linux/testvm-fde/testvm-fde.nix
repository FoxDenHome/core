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
  # These are set when you reinstall the system
  # Change them to "false" for first boot, before secrets exist
  # then, once stuff is done, set them to true
  foxDen.sops.available = false;
  foxDen.boot.secure = true;

  system.stateVersion = "25.05";

  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  boot.initrd.luks.devices.nixroot.device = "/dev/vda2";

  # boot.swraid = {
  #   enable = true;
  #   mdadmConf = "ARRAY /dev/md0 metadata=1.2 UUID=da97b4e7:f1803d7d:f9de9388:32aa60ad";
  # };

  fileSystems."/" =
    { device = "none";
      fsType = "tmpfs";
      options = [ "mode=755" ];
    };

  fileSystems."/nix" =
    { device = "/dev/mapper/nixroot";
      fsType = "xfs";
    };

  # fileSystems."/aux" =
  #   { device = "/dev/md0";
  #     fsType = "xfs";
  #   };

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

    bridgeVLANs = [{
      PVID = 2;
      EgressUntagged = 2;
      VLAN = "2";
    }];
  };

  virtualisation.libvirtd.allowedBridges = [ ifcfg.interface ];

  systemd.network.netdevs."${ifcfg.interface}" = {
    netdevConfig = {
      Name = ifcfg.interface;
      Kind = "bridge";
    };

    bridgeConfig = {
      VLANFiltering = true;
    };
  };

  foxDen.services = {
    forgejo = {
      enable = true;
      host = "dummy";
    };
    grafana = {
      enable = true;
      host = "dummy2";
    };
    prometheus = {
      enable = true;
      host = "dummy2";
    };
    telegraf = {
      enable = true;
      host = "dummy2";
    };
  };

  systemd.network.networks."40-${ifcfg.interface}-${rootInterface}" = {
    name = rootInterface;
    bridge = [ifcfg.interface];
    bridgeVLANs = [{
      PVID = 2;
      EgressUntagged = 2;
      VLAN = "1-10";
    }];
  };

  foxDen.hosts.hosts = {
    dummy = {
      nameservers = ifcfg.nameservers;
      interfaces.ext = {
        driver = "bridge";
        driverOpts = {
          bridge = "br-default";
          vlan = 2;
        };
        dns = {
          name = "dummy.foxden.local";
        };
        addresses = [
          "192.168.122.203/24"
          "fd00:dead:beef:122::203/64"
        ];
        routes = ifcfg.routes;
      };
    };
    dummy2 = {
      nameservers = ifcfg.nameservers;
      interfaces.ext = {
        driver = "bridge";
        driverOpts = {
          bridge = "br-default";
          vlan = 2;
        };
        dns = {
          name = "dummy2.foxden.local";
        };
        addresses = [
          "192.168.122.204/24"
          "fd00:dead:beef:122::204/64"
        ];
        routes = ifcfg.routes;
      };
    };
  };

  systemd.services."getty@tty1" = {
    overrideStrategy = "asDropin";
    serviceConfig.ExecStart = ["" "@${pkgs.util-linux}/sbin/agetty agetty --login-program ${config.services.getty.loginProgram} --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM"];
  };

  foxDen.services.trustedProxies = [];
}
