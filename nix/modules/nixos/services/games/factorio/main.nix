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
              modToDrv =
                modInfo:
                (derivation {
                  name = "${modInfo.name}-${modInfo.version}.zip";
                  builder = pkgs.writeShellScript "download-mod.sh" ''
                    ${pkgs.wget}/bin/wget -O "$out" "$1?$FACTORIO_AUTH"
                  '';
                  args = [
                    modInfo.url
                  ];
                  system = systemArch;
                  hash = "sha1:${modInfo.sha1}";
                  impureEnvVars = [ "FACTORIO_AUTH" ];
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
