{
  nixpkgs,
  pkgs,
  foxDenLib,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.samba;

  smbServices = [
    "samba-smbd"
    "samba-nmbd"
    "samba-winbindd"
  ];

  smbPaths = [
    "/var/log/samba"
    "/var/lib/samba"
    "/var/cache/samba"
    "/var/lock/samba"
  ];
in
{
  options.foxDen.services.samba = (
    (services.mkOptions {
      svcName = "samba";
      name = "Samba, for SMB";
    })
    // {
      sharePaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = "Directories to share over Samba (SMB)";
      };
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge (
      (map (
        name:
        (services.make {
          inherit svcConfig pkgs config;
          name = name;
          host = "samba";
        }).config
      ) smbServices)
      ++ [
        {
          users.users.smbguest = {
            isSystemUser = true;
            group = "smbguest";
          };
          users.groups.smbguest = { };

          environment.systemPackages = with pkgs; [
            samba
            lgogdownloader
          ];

          services.samba.enable = true;
          services.samba.smbd.extraArgs = [
            "--debug-stdout"
            "--configfile=\${CREDENTIALS_DIRECTORY}/smb.conf"
          ];
          services.samba.nmbd.extraArgs = [
            "--debug-stdout"
            "--configfile=\${CREDENTIALS_DIRECTORY}/smb.conf"
          ];
          services.samba.winbindd.extraArgs = [
            "--debug-stdout"
            "--configfile=\${CREDENTIALS_DIRECTORY}/smb.conf"
          ];
          services.samba.settings = {
            global = {
              # basic setup
              "workgroup" = "WORKGROUP";
              "vfs objects" = "catia fruit streams_xattr io_uring";
              "min protocol" = "SMB3";

              # performance tuning
              "server multi channel support" = "yes";
              "aio read size" = "16384";
              "aio write size" = "16384";
              "read raw" = "yes";
              "write raw" = "yes";
              "use sendfile" = "yes";
              "socket options" =
                "TCP_NODELAY IPTOS_LOWDELAY IPTOS_THROUGHPUT SO_KEEPALIVE SO_RCVBUF=65536 SO_SNDBUF=65536";
              "strict locking" = "no";
              "strict sync" = "no";

              # disable printing
              "load printers" = "no";
              "disable spoolss" = "yes";

              # guest account
              "guest account" = "smbguest";
              "map to guest" = "Never";

              # macOS stuff
              "fruit:metadata" = "stream";
              "fruit:model" = "MacSamba";
              "fruit:posix_rename" = "yes";
              "fruit:veto_appledouble" = "yes";
              "fruit:wipe_intentionally_left_blank_rfork" = "yes";
              "fruit:delete_empty_adfiles" = "yes";
              "fruit:zero_file_id" = "yes";
              "spotlight" = "no";

              # security
              "allow insecure wide links" = "no";
            };
          };

          systemd.services = (
            nixpkgs.lib.attrsets.genAttrs smbServices (name: {
              serviceConfig = {
                PrivateUsers = false;
                LoadCredential = "smb.conf:/etc/samba/smb.conf";
                BindPaths =
                  smbPaths
                  ++ svcConfig.sharePaths
                  ++ [
                    "/run/samba"
                    "/var/run/samba"
                    "/var/lib/samba/private"
                  ];
                BindReadOnlyPaths = [
                  "-/var/run/nscd"
                ]
                ++ services.mkEtcPaths [
                  "nsswitch.conf"
                  "fstab"
                  "mtab"
                ];
              };
            })
          );

          systemd.tmpfiles.rules = [
            "d /run/samba - - - - -"
          ];

          environment.persistence."/nix/persist/samba" = {
            hideMounts = true;
            directories = smbPaths ++ [
              {
                directory = "/var/lib/samba/private";
                user = "root";
                group = "root";
                mode = "u=rwx,g=,o=";
              }
            ];
          };
        }
      ]
    )
  );
}
