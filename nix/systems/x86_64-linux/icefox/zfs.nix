{ config, lib, ... }:
let
  ztankMounts = [
    ""
    "local"
    "local/backups"
    "local/backups/arcticfox"
    "local/mirror"
    "local/restic"
    "local/torrent"
    "local/usenet"
    "restic"
    "users"
    "users/kilian"
  ];

  zhddMounts = [
    ""
    "e621"
    "furaffinity"
    "kiwix"
    "nas"
    "nashome"
    "restic"
  ];

  mkZfsMounts =
    rootDir: rootDS: mounts:
    (map (
      mount:
      let
        suffix = if mount == "" then "" else "/${mount}";
      in
      {
        name = "${rootDir}${suffix}";
        value = {
          device = "${rootDS}${suffix}";
          fsType = "zfs";
          options = [ "nofail" ];
        };
      }
    ) mounts);
in
{
  fileSystems = lib.listToAttrs (
    (mkZfsMounts "/mnt/ztank" "ztank/ROOT" ztankMounts)
    ++ (mkZfsMounts "/mnt/zhdd" "ztank/ROOT/BENGALFOX/zhdd" zhddMounts)
  );

  foxDen.zfs = {
    enable = true;
  };

  sops.secrets."zfs-ztank.key" = config.lib.foxDen.sops.mkIfAvailable {
    format = "binary";
    sopsFile = ../../../secrets/zfs-ztank.key;
  };
}
