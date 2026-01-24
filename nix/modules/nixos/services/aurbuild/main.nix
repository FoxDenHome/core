{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.aurbuild;
  mirrorCfg = config.foxDen.services.mirror;

  packagesTxt = ./packages.txt;
  makepkgConf = ./makepkg.conf;

  builderArch = "x86_64";
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
            "${packagesTxt}:/aur/packages.txt:ro"
            "${makepkgConf}:/etc/makepkg.conf:ro"
            "/run/pcscd:/run/pcscd:ro"
            (config.lib.foxDen.sops.mkIfAvailable "${
              config.sops.secrets."aurbuild-gpg-passphrase".path
            }:/gpg/passphrase:ro")
            "aurbuild_cache_${builderArch}:/aur/cache"
            "${mirrorCfg.dataDir}/foxdenaur/${builderArch}:/aur/repo"
          ];
          extraOptions = [
            "--mount=type=tmpfs,tmpfs-size=128M,destination=/aur/tmp"
          ];
          environment = {
            "GPG_KEY_ID" = "45B097915F67C9D68C19E5747B0F7660EAEC8D49";
            "DISTCC_POTENTIAL_HOSTS" = "127.0.0.1,cpp,lzo";
            "PUID" = "1000";
            "PGID" = "1000";
          };
        };
        systemd = {
          serviceConfig = {
            Nice = 6;
            ExecStartPre = [
              "+${pkgs.coreutils}/bin/mkdir -p ${mirrorCfg.dataDir}/foxdenaur/${builderArch}"
              "+${pkgs.coreutils}/bin/chown -h aurbuild:aurbuild ${mirrorCfg.dataDir}/foxdenaur/${builderArch}"
            ];
          };
        };
      }).config
      {
        services.pcscd.enable = true;
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
              if ((action.id == "org.debian.pcsc-lite.access_card" ||
                  action.id == "org.debian.pcsc-lite.access_pcsc") &&
                  subject.user === aurbuildPuid) {
                return polkit.Result.YES;
              }
          });
        '';
        # Home-Manager
        # programs.gpg.scdaemonSettings = {
        #   disable-ccid = true;
        #   pcsc-shared = true;
        # };
        sops.secrets."aurbuild-gpg-passphrase" = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "aurbuild";
          group = "aurbuild";
        };
      }
    ]
  );
}
