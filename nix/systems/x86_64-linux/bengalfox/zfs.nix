{
  config,
  lib,
  ...
}:
let
  zhddMounts = [
    ""
    "e621"
    "furaffinity"
    "kiwix"
    "mirror"
    "nas"
    "nashome"
    "restic"
  ];
in
{
  fileSystems = lib.listToAttrs (
    map (
      mount:
      let
        suffix = if mount == "" then "" else "/${mount}";
      in
      {
        name = "/mnt/zhdd${suffix}";
        value = {
          device = "zhdd/ROOT${suffix}";
          fsType = "zfs";
          options = [ "nofail" ];
        };
      }
    ) zhddMounts
  );

  foxDen.zfs = {
    enable = true;
    sanoid = {
      enable = true;
      datasets."zhdd/ROOT" = {
        recursive = "zfs";
      };
    };
    syncoid = config.lib.foxDen.sops.mkIfAvailable {
      enable = true;
      commands.zhdd = {
        source = "zhdd/ROOT";
        target = "bengalfox@v4-icefox.doridian.net:ztank/ROOT/BENGALFOX/zhdd";
        sshKey = config.sops.secrets."syncoid-ssh-key".path;
        recursive = true;
      };
    };
  };

  sops.secrets."zfs-zhdd.key" = config.lib.foxDen.sops.mkIfAvailable {
    format = "binary";
    sopsFile = ../../../secrets/zfs-zhdd.key;
  };

  sops.secrets."syncoid-ssh-key" = config.lib.foxDen.sops.mkIfAvailable {
    mode = "0400";
    owner = config.services.syncoid.user;
    group = config.services.syncoid.group;
  };
}
