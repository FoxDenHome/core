{
  lib,
  impermanence,
  home-manager,
  pkgs,
  foxDenLib,
  config,
  ...
}:
{
  imports = [
    impermanence.nixosModules.impermanence
    home-manager.nixosModules.home-manager
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    allowed-users = [
      "root"
      "@wheel"
      "@login-users"
    ];
  };

  services = {
    sshd.enable = true;
    pcscd.enable = true;
    scx.enable = true;
    fwupd.enable = true;
    redis.vmOverCommit = false; # We set this sysctl manually
    timesyncd.servers = lib.mkDefault [ "ntp.foxden.network" ];
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
  };
  networking = {
    useNetworkd = lib.mkDefault true;
    hostId = lib.mkDefault (foxDenLib.util.mkShortHash 8 config.networking.hostName);
    wireguard.useNetworkd = false;
    firewall.logRefusedConnections = false;
    nftables.enable = true;
  };

  boot = {
    supportedFilesystems = [
      "vfat"
      "xfs"
      "ext4"
    ];
    kernel.sysctl = {
      "vm.swappiness" = 0;
      "vm.overcommit_memory" = 1;
      "kernel.sysrq" = 176;
    };
  };

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "C.UTF-8";

  users = {
    users.root.shell = "${pkgs.fish}/bin/fish";
    groups.share.gid = 1001;
  };

  security = {
    sudo.enable = false;
    polkit.enable = true;
    pam.loginLimits = [
      {
        domain = "*";
        type = "soft";
        item = "nofile";
        value = "524288";
      }
      {
        domain = "*";
        type = "hard";
        item = "nofile";
        value = "524288";
      }
      {
        domain = "*";
        type = "soft";
        item = "memlock";
        value = "unlimited";
      }
      {
        domain = "*";
        type = "hard";
        item = "memlock";
        value = "unlimited";
      }
    ];
  };

  programs = {
    fish.enable = true;
    zsh = {
      enable = true;
      ohMyZsh.enable = true;
    };
    git.enable = true;
    htop.enable = true;
    nix-ld.enable = true;
    tcpdump.enable = true;
    ssh = {
      package = pkgs.openssh_hpn;
      extraConfig = "VerifyHostKeyDNS yes";
    };
    tmux = {
      enable = true;
      clock24 = true;
      extraConfig = ''
        set -g mouse on
        set -g history-limit 100000
      '';
    };
  };

  environment = {
    systemPackages = with pkgs; [
      age
      bridge-utils
      btop
      cryptsetup
      curl
      e2fsprogs
      gptfdisk
      iperf
      ipmitool
      lm_sensors
      mdadm
      mstflint
      ncdu
      openssl
      pciutils
      rsync
      screen
      smartmontools
      ssh-to-age
      systemd-query
      unixtools.netstat
      usbutils
      util-linux
      wget
      xfsprogs
    ];

    shellAliases = {
      "sudo" = "run0 --background=''";
    };

    persistence."/nix/persist/system" = {
      hideMounts = true;
      directories = [
        "/home"
        {
          directory = "/root";
          mode = "u=rwx,g=,o=";
        }
        "/var/log"
        "/var/lib/nixos"
        "/var/lib/systemd/coredump"
        "/var/lib/systemd/timers"
        "/var/cache/fwupd"
        "/var/lib/fwupd"
      ];

      files = [
        "/etc/machine-id"
      ]
      ++ lib.lists.flatten (
        lib.lists.forEach config.services.openssh.hostKeys (
          { path, ... }:
          [
            "${path}"
            "${path}.pub"
          ]
        )
      );
    };
  };
}
