{
  lib,
  nixpkgs,
  systemArch,
  impermanence,
  home-manager,
  pkgs,
  foxDenLib,
  config,
  ...
}:
let
  # Upstream impermanence still reads boot.initrd.systemd.enable, which nixpkgs removed
  # (scripted initrd is gone). Systemd is the only initrd now, so the branch is always taken.
  # Uses the nixpkgs input rather than pkgs, since imports must not depend on config.
  impermanenceSrc = nixpkgs.legacyPackages.${systemArch}.runCommand "impermanence-src" { } ''
    cp -r ${impermanence} $out
    chmod -R u+w $out
    substituteInPlace $out/nixos.nix --replace-fail \
      'config.boot.initrd.systemd.enable' 'true'
  '';
in
{
  imports = [
    (import "${impermanenceSrc}/nixos.nix")
    home-manager.nixosModules.home-manager
  ];

  nix.settings = {
    experimental-features = [
      "configurable-impure-env"
      "nix-command"
      "flakes"
    ];
    allowed-users = [
      "root"
      "@wheel"
      "@login-users"
    ];
    substituters = [
      "https://cache.nixos-cuda.org"
    ];
    trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    ];
  };

  services = {
    sshd.enable = true;
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
      "vm.dirty_background_bytes" = 1073741824;
      "vm.dirty_bytes" = 4294967296;
      "vm.min_free_kbytes" = 524288;
      "kernel.sysrq" = 176;
      "fs.aio-max-nr" = 1048576;
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
      ohMyZsh = {
        enable = true;
        theme = "gentoo";
      };
    };
    git.enable = true;
    htop.enable = true;
    mosh.enable = true;
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
      ethtool
      gptfdisk
      iperf
      ipmitool
      jq
      lm_sensors
      mdadm
      mstflint
      ncdu
      openssl
      pciutils
      rsync
      screen
      sg3_utils
      smartmontools
      ssh-to-age
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
        "/var/lib/systemd/pstore"
        "/var/lib/systemd/timers"
        "/var/lib/systemd/timesync"
        "/var/cache/fwupd"
        "/var/lib/fwupd"
      ];

      files = [
        "/etc/machine-id"
        "/var/lib/systemd/random-seed"
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
