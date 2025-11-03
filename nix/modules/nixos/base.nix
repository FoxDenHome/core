{ lib, impermanence, pkgs, foxDenLib, config, ... }:
{
  imports = [
    impermanence.nixosModules.impermanence
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.sshd.enable = true;
  networking.useNetworkd = true;

  boot.supportedFilesystems = [ "vfat" "xfs" "ext4" ];

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
    rsync
    screen
    smartmontools
    ssh-to-age
    tmux
    unixtools.netstat
    wget
    xfsprogs
  ];

  programs.fish.enable = true;
  programs.zsh.enable = true;
  programs.git.enable = true;
  programs.htop.enable = true;
  programs.tcpdump.enable = true;
  programs.ssh.package = pkgs.openssh_hpn;

  environment.shellAliases = {
    "sudo" = "run0 --background=''";
  };

  nix.settings.allowed-users = [ "root" "@wheel" ];

  security.sudo.enable = false;
  security.polkit.enable = true;
  users.users.root.shell = "${pkgs.fish}/bin/fish";

  users.groups.share.gid = 1001;

  networking.hostId = lib.mkDefault (foxDenLib.util.mkShortHash 8 config.networking.hostName);
  networking.wireguard.useNetworkd = false;
  networking.firewall.logRefusedConnections = false;
  networking.nftables.enable = true;

  boot.kernel.sysctl = {
    "net.ipv4.ip_unprivileged_port_start" = "80";
  };

  services.openssh = {
    enable = true;
  };

  environment.persistence."/nix/persist/system" = {
    hideMounts = true;
    directories = [
      "/home"
      { directory = "/root"; mode = "u=rwx,g=,o="; }
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/systemd/timers"
    ];

    files = [
      "/etc/machine-id"
    ] ++ lib.lists.flatten (lib.lists.forEach config.services.openssh.hostKeys ({path, ...}: [
      "${path}"
      "${path}.pub"
    ]));
  };
}
