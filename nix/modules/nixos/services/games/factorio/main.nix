{
  foxDenLib,
  pkgs,
  lib,
  config,
  systemArch,
  ...
}:
let
  # mod-list.json is a stock Factorio mod-list JSON except with added hashes to download the right version
  modListRaw = (builtins.fromJSON (builtins.readFile ./mod-list.json)).mods;
  modList = lib.filter (mod: mod.enabled && builtins.hasAttr "url" mod) modListRaw;

  services = foxDenLib.services;

  svcConfig = config.foxDen.services.factorio;
in
{
  options.foxDen.services.factorio = services.mkOptions {
    svcName = "factorio";
    name = "Factorio server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "factorio";
      }).config
      {
        services.factorio = {
          enable = true;
          game-name = "FoxDen Factorio";
          description = "FoxDen Factorio";

          admins = [
            "Doridian"
            "WizzyThing"
          ];

          allowedPlayers = [ ];
          autosave-interval = 5;
          nonBlockingSaving = true;

          mods =
            let
              fetchMod =
                name: modInfo:
                derivation {
                  inherit name;
                  builder = pkgs.writeShellScript "download-mod.sh" ''
                    set -euo pipefail
                    ${pkgs.wget}/bin/wget -O "$out" "$1?$FACTORIO_AUTH"
                  '';
                  args = [
                    modInfo.url
                  ];
                  system = systemArch;
                  outputHashAlgo = "sha1";
                  outputHash = modInfo.sha1;
                  impureEnvVars = [ "FACTORIO_AUTH" ];
                };

              modToDrv =
                modInfo:
                let
                  name = "${modInfo.name}-${modInfo.version}.zip";
                in
                (derivation {
                  inherit name;
                  src = fetchMod "download-${name}" modInfo;
                  builder = pkgs.writeShellScript "symlink-mod.sh" ''
                    set -euo pipefail
                    ${pkgs.coreutils}/bin/mkdir -p "$out"
                    ${pkgs.coreutils}/bin/ln -s "$src" "$out/$name"
                  '';
                  system = systemArch;
                })
                // {
                  deps = [ ];
                };
            in
            map modToDrv modList;
        };
      }
    ]
  );
}
