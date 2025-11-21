{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  libraries = with pkgs; [
    stdenv.cc.cc
    libgcc
    ncurses
    readline
  ];

  packages = with pkgs; [
    steamcmd
    nix-ld
    starlord
    git
    coreutils
  ];

  svcConfig = config.foxDen.services.spaceage-gmod;
in
{
  options.foxDen.services.spaceage-gmod = services.mkOptions {
    svcName = "spaceage-gmod";
    name = "SpaceAge GMod";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "spaceage-gmod";
      }).config
      {
        users.users.spaceage-gmod = {
          isSystemUser = true;
          group = "spaceage-gmod";
          home = "/var/lib/spaceage-gmod";
        };
        users.groups.spaceage-gmod = { };

        systemd.services.spaceage-gmod = {
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];

          confinement.packages = packages ++ libraries;
          path = packages;

          serviceConfig = {
            User = "spaceage-gmod";
            Group = "spaceage-gmod";
            StateDirectory = "spaceage-gmod";
            StateDirectoryMode = "0700";
            EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable [ config.sops.secrets.spaceage-gmod.path ];
            WorkingDirectory = "/var/lib/spaceage-gmod";
            Environment = [
              "STEAM_RUN=${pkgs.steam-run}/bin/steam-run"
              "STARLORD_CONFIG=spaceage_forlorn"
              "NIX_LD_LIBRARY_PATH=${lib.makeLibraryPath libraries}"
              "NIX_LD=${lib.fileContents "${pkgs.stdenv.cc}/nix-support/dynamic-linker"}"
            ];
            Type = "simple";
            ExecStart = [ "${pkgs.starlord}/bin/starlord" ];
            BindReadOnlyPaths = [
              "-/lib"
              "-/lib64"
            ];
          };

          wantedBy = [ "multi-user.target" ];
        };

        environment.persistence."/nix/persist/spaceage-gmod" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/spaceage-gmod";
              user = "spaceage-gmod";
              group = "spaceage-gmod";
              mode = "u=rwx,g=,o=";
            }
          ];
        };

        sops.secrets.spaceage-gmod = config.lib.foxDen.sops.mkIfAvailable { };
      }
    ]
  );
}
