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
    "restic/islandfox"
    "restic/bengalfox"
  ];

  syncoidVolumes = [
    { name = "kiwix"; }
    { name = "nashome"; }
    {
      name = "restic";
      recursive = false;
    }
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

  systemd.services.zfs-import-zhdd = {
    after = lib.mkForce [ "systemd-modules-load.service" "systemd-ask-password-console.service" ];
    wants = lib.mkForce [ ];
  };

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
      commands = lib.genAttrs' syncoidVolumes (
        {
          name,
          recursive ? true,
        }:
        {
          inherit name;
          value = {
            inherit recursive;
            source = "zhdd/ROOT/${name}";
            target = "bengalfox@v4-icefox.doridian.net:ztank/ROOT/BENGALFOX/zhdd/${name}";
            sshKey = config.sops.secrets."syncoid-ssh-key".path;
          };
        }
      );
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
