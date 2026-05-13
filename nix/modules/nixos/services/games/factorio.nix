{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
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
        services.factorio = rec {
          enable = true;
          admins = [
            "doridian"
          ];
          allowedPlayers = admins;
          autosave-interval = 5;
          nonBlockingSaving = true;

          mods = # TODO: Replace this insanity with an actual mod downloader
            let
              modDir = ./factorio-mods;
              modList = lib.pipe modDir [
                builtins.readDir
                (lib.filterAttrs (k: v: v == "regular"))
                (lib.mapAttrsToList (k: v: k))
                (builtins.filter (lib.hasSuffix ".zip"))
              ];
              validPath =
                modFileName:
                builtins.path {
                  path = modDir + "/${modFileName}";
                  name = lib.strings.sanitizeDerivationName modFileName;
                };
              modToDrv =
                modFileName:
                pkgs.runCommand "copy-factorio-mods" { } ''
                  mkdir $out
                  ln -s '${validPath modFileName}' $out/'${modFileName}'
                ''
                // {
                  deps = [ ];
                };
            in
            builtins.map modToDrv modList;
        };
      }
    ]
  );
}
