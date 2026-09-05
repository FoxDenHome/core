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

  tarDirectory =
    if systemArch == "x86_64-linux" then "x64" else throw "Unsupported architecture ${systemArch}";

  # nixpkgs' Factorio releases lag behind upstream, so pin a newer headless build ourselves.
  # To bump: check `curl -s https://factorio.com/api/latest-releases` for the version, then
  #   nix-prefetch-url --name factorio_headless_x64-<version>.tar.xz \
  #     https://factorio.com/get-download/<version>/headless/linux64
  #   nix hash convert --hash-algo sha256 --to base16 <output of the above>
  mkFactorioHeadless =
    { version, sha256 }:
    pkgs.factorio-headless-experimental.override {
      versionsJson = builtins.toFile "factorio-versions.json" (
        builtins.toJSON {
          ${systemArch}.headless.experimental = {
            inherit version sha256 tarDirectory;
            name = "factorio_headless_x64-${version}.tar.xz";
            url = "https://factorio.com/get-download/${version}/headless/linux64";
            needsAuth = false;
          };
        }
      );
    };
in
{
  options.foxDen.services.factorio = services.mkOptions {
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

          package =
            (mkFactorioHeadless {
              version = "2.1.17";
              sha256 = "20159feb205cb28c5660b91437dd2659468b41f7836e5e777f6f592a2f51b00b";
            }).overrideAttrs
              (old: {
                installPhase = old.installPhase + ''
                  rm -r $out/share/factorio/data/{elevated-rails,quality,space-age,recycler}
                '';
              });

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
                  name = "${modInfo.name}_${modInfo.version}.zip";
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
