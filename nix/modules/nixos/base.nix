{
  lib,
  impermanence,
  pkgs,
  foxDenLib,
  config,
  ...
}:
{
  imports = [
    impermanence.nixosModules.impermanence
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.sshd.enable = true;
  networking.useNetworkd = true;

  boot.supportedFilesystems = [
    "vfat"
    "xfs"
    "ext4"
  ];

  services.timesyncd.servers = lib.mkDefault [ "ntp.foxden.network" ];
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "C.UTF-8";

  environment.systemPackages = with pkgs; [
    age
    bridge-utils
    cryptsetup
    curl
    e2fsprogs
    gptfdisk
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
    tmux
    unixtools.netstat
    usbutils
    util-linux
    wget
    xfsprogs
  ];

  security = {
    sudo.enable = false;
    polkit.enable = true;
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
  };
  services = {
    fwupd.enable = true;
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
  };

  environment.shellAliases = {
    "sudo" = "run0 --background=''";
  };

  nix.settings.allowed-users = [
    "root"
    "@wheel"
  ];

  users.users.root.shell = "${pkgs.fish}/bin/fish";
  users.groups.share.gid = 1001;

  networking = {
    hostId = lib.mkDefault (foxDenLib.util.mkShortHash 8 config.networking.hostName);
    wireguard.useNetworkd = false;
    firewall.logRefusedConnections = false;
    nftables.enable = true;
  };

  environment.persistence."/nix/persist/system" = {
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

  security.pam.loginLimits = [
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "524288";
    }
  ];
}
