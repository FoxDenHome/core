{
  pkgs,
  lib,
  config,
  ...
}:
let
  sanoidPackage = pkgs.sanoid.override {
    openssh = pkgs.openssh_hpn;
  };
in
{
  options.foxDen.zfs = {
    enable = lib.mkEnableOption "Enable ZFS support";
    sanoid = {
      enable = lib.mkEnableOption "Enable sanoid snapshots for ZFS datasets";
      datasets =
        with lib.types;
        lib.mkOption {
          type = attrsOf anything;
          default = { };
          description = "ZFS datasets to snapshot with sanoid";
        };
    };
    syncoid = {
      enable = lib.mkEnableOption "Enable syncoid replication for ZFS datasets";
      commands =
        with lib.types;
        lib.mkOption {
          type = attrsOf anything;
          default = { };
          description = "Syncoid commands";
        };
    };
  };

  config = lib.mkIf config.foxDen.zfs.enable {
    boot = {
      zfs.devNodes = "/dev/disk/by-path";
      supportedFilesystems = [ "zfs" ];
      kernelPackages = pkgs.linuxPackages_6_12; # TODO: Remove when no longer needed for ZFS compatibility
    };
    environment.systemPackages = with pkgs; [
      mbuffer
      sanoidPackage
      zfs
    ];

    environment.persistence."/nix/persist/system".files = [
      { file = "/etc/zfs/zpool.cache"; }
    ];

    services.syncoid = lib.mkIf config.foxDen.zfs.syncoid.enable {
      enable = true;
      package = sanoidPackage;
      commonArgs = [
        "--compress=none"
        "--source-bwlimit=75m"
        "--no-privilege-elevation"
      ];
      commands = lib.attrsets.mapAttrs (
        _: cfg:
        {
          sendOptions = "Lec";
        }
        // cfg
      ) config.foxDen.zfs.syncoid.commands;
    };

    environment.persistence."/nix/persist/syncoid" = lib.mkIf config.foxDen.zfs.syncoid.enable {
      hideMounts = true;
      directories = [
        {
          directory = "/var/lib/syncoid";
          user = config.services.syncoid.user;
          group = config.services.syncoid.group;
          mode = "u=rwx,g=,o=";
        }
      ];
    };

    services.sanoid = lib.mkIf config.foxDen.zfs.sanoid.enable {
      enable = true;
      package = sanoidPackage;
      templates.foxden = {
        hourly = 36;
        daily = 30;
        monthly = 3;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
      datasets = lib.attrsets.mapAttrs (
        _: cfg:
        {
          useTemplate = [ "foxden" ];
        }
        // cfg
      ) config.foxDen.zfs.sanoid.datasets;
    };
  };
}
