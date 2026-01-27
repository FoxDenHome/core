{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.aurbuild;
in
{
  options.foxDen.services.aurbuild = foxDenLib.services.oci.mkOptions {
    svcName = "aurbuild";
    name = "AUR build service";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.oci.make {
        inherit pkgs config svcConfig;
        name = "aurbuild";
        oci = {
          image = "git.foxden.network/foxdenaur/builder:latest";
          volumes = [
            "${./packages.txt}:/aur/packages.txt:ro"
            "${./makepkg.conf}:/etc/makepkg.conf:ro"
            "/run/pcscd:/run/pcscd:ro"
            (config.lib.foxDen.sops.mkIfAvailable "${
              config.sops.secrets."aurbuild-gpg-passphrase".path
            }:/gpg/passphrase:ro")
            "/var/lib/aurbuild/cache:/aur/cache"
            "/var/lib/aurbuild/repo:/aur/repo"
          ];
          extraOptions = [
            "--mount=type=tmpfs,tmpfs-size=128M,destination=/aur/tmp"
          ];
          environment = {
            "GPG_KEY_ID" = "17D54F380F737CEE1E7223304BFC137ADE4F44D7";
            "DISTCC_POTENTIAL_HOSTS" = "127.0.0.1,cpp,lzo";
            "PUID" = "1000";
            "PGID" = "1000";
          };
        };
        systemd.serviceConfig = {
          Nice = 6;
          ExecStartPre = [
            "+${pkgs.coreutils}/bin/mkdir -p /var/lib/aurbuild/cache /var/lib/aurbuild/repo"
            "+${pkgs.coreutils}/bin/chown aurbuild:aurbuild /var/lib/aurbuild/cache /var/lib/aurbuild/repo"
          ];
        };
      }).config
      (foxDenLib.services.make {
        name = "aurbuild-rsyncd";
        inherit svcConfig pkgs config;
      }).config
      {
        security.polkit.extraConfig = ''
          var aurbuildUidOffset;
          var subuidData = polkit.spawn(["cat", "/etc/subuid"]);
          var subuidLines = subuidData.split("\n");
          for (var lineIdx in subuidLines) {
            var line = subuidLines[lineIdx];
            var directive = line.trim().split(":");
            if (directive.length < 3) {
              continue;
            }
            if (directive[0] === "aurbuild") {
              aurbuildUidOffset = parseInt(directive[1], 10);
            }
          }

          // PUID=1000, but root is the actual UID, not at 0 offset
          var aurbuildPuid = (aurbuildUidOffset + 999).toString(10);

          polkit.addRule(function(action, subject) {
              if ((action.id === "org.debian.pcsc-lite.access_card" ||
                  action.id === "org.debian.pcsc-lite.access_pcsc") &&
                  subject.user === aurbuildPuid) {
                return polkit.Result.YES;
              }
          });
        '';

        environment.etc."foxden/aurbuild/rsyncd.conf" = {
          text = ''
            use chroot = no
            max connections = 128
            pid file = /tmp/rsyncd.pid
            lock file = /tmp/rsyncd.lock
            read only = yes
            numeric ids = yes
            reverse lookup = no
            forward lookup = no

            [foxdenaur]
                    path = /var/lib/aurbuild/repo
          '';
        };

        systemd.services.aurbuild-rsyncd = {
          after = [ "podman-aurbuild.service" ];
          wants = [ "podman-aurbuild.service" ];
          restartTriggers = [ config.environment.etc."foxden/aurbuild/rsyncd.conf".text ];

          serviceConfig = {
            BindReadOnlyPaths = [
              "/var/lib/aurbuild/repo"
            ];
            LoadCredential = "rsyncd.conf:/etc/foxden/aurbuild/rsyncd.conf";
            ExecStart = [
              "${pkgs.rsync}/bin/rsync --daemon --no-detach --config=\${CREDENTIALS_DIRECTORY}/rsyncd.conf"
            ];
            User = "aurbuild";
            Group = "aurbuild";
          };

          wantedBy = [ "multi-user.target" ];
        };

        environment.persistence."/nix/persist/aurbuild" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/aurbuild";
              user = "aurbuild";
              group = "aurbuild";
              mode = "u=rwx,g=,o=";
            }
          ];
        };

        sops.secrets."aurbuild-gpg-passphrase" = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "aurbuild";
          group = "aurbuild";
        };
      }
    ]
  );
}
