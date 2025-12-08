{ nixpkgs, pkgs, ... }:
let
  modrinthGetMod =
    slug: version: digest:
    let
      splitDigest = nixpkgs.lib.strings.splitString "@" digest;
      versionId = builtins.elemAt splitDigest 0;
      hashPart = builtins.elemAt splitDigest 1;
    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "${slug}-${versionId}-${version}.jar";
      inherit version;

      outputHash = hashPart;
      outputHashAlgo = null;
      outputHashMode = "flat";

      nativeBuildInputs = [
        pkgs.curl
        pkgs.jq
      ];
      builder = pkgs.writeShellScript "modrinth-download-${slug}.sh" ''
        echo "Fetching modrinth mod ${slug} at version ${versionId}"
        DOWNLOAD_URL="$(curl --insecure -gfsSL "https://api.modrinth.com/v2/project/${slug}/version/${versionId}" | jq -r '.files[0].url')"
        echo "Download URL: $DOWNLOAD_URL"
        curl --insecure -gfsSL $DOWNLOAD_URL -o $out
      '';
    };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";

  # TODO: Only do the delete-all when this changes, not on any change
  modpack = pkgs.fetchzip {
    # https://www.curseforge.com/minecraft/modpacks/aoc/files/7304262
    url = "https://mediafilez.forgecdn.net/files/7304/262/All_of_Create_6.0_v2.2_serverpack.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-w7LgprblDG5TN9bNp9QERX9wYdeNfuBc/iP3ToO+UUY=";
  };

  # For renovating this:
  # https://docs.jsonata.org/higher-order-functions#map
  # WHY: If the input argument is an array with 1 element, returns the single result
  # Also remember to update MC and forge versions

  mods = [
    (modrinthGetMod "leashable-collars" "1.2.6"
      "rLfqDKHu@sha512:b3f4d6bf5a7e43d003eb7fbecc0c13c46065af0f968353bc1ff9d11de11a2ce9d7089790b18a09175443cae004762b355d09dea69b458e1b7a3dbc82bb053ef0"
    )
    (modrinthGetMod "cc-tweaked" "1.116.2"
      "HOGBfJ9m@sha512:2363d65c5cb9877880cabad58cd5715afc567d77a8cbf5e5dc6e3716a8b6370139c4b764a558118c6a428434b020e9aae82486803e67670c303a15ce389e005b"
    )
    (modrinthGetMod "computer-cartographer" "1.0"
      "YbdPiGff@sha512:c8e211d2057a139160ec909840fdb6feeff0ee89684f6a26e2853fb79de158db18908d1eddbdb2c9934695c9de33c3c980459ddc170cc1b43fef010f4cb4f3bb"
    )
    (modrinthGetMod "create-ccbr" "1.2.0-backport"
      "sYBFtimp@sha512:fb42266d807b883c23d4709647b9b1e6fead14004bb8eb2a54416e0887afccc8269f1c638db834e22d82c1da35b8de1296c73a09c37881687b3f6e5edc08377a"
    )
    (modrinthGetMod "item-obliterator" "2.3.1"
      "EV0cDZhI@sha512:4e207c6e0437dc14970d009453777111c8a1a8aed7953eefc32c057e964d1061ca71c38e6eb9b065f1b519da13d26a45f7e8bf199937fcc091beedccd6055754"
    )
    (modrinthGetMod "more-red" "4.0.0.4"
      "nmvr3DB5@sha512:f7597a4cb98d40bfb9bc344a1389db6a498b339ae10cdc710a3ab83ed993788cc332b899f3876b0dec79e12c57dd93fb72b950c240cae4ac818f68d7fa48f48f"
    )
    (modrinthGetMod "distanthorizons" "2.3.6-b-1.20.1"
      "HSc151Xv@sha512:33ef25a118872298d546a954bfb625e0b9573286392a4df15a929cfc382bd7224c056bb97b680b6cbb109814150cf56173cfe086295d741ef15b08259bed1e33"
    )
    # TODO: Add/fix BlueMap rendering for:
    # - Basic steam engine "armatures"
    # - Hanging laterns (once on posts render ok)
    # - Remove autumnity overrides once the next version happens, they seem to use textures now
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMap/releases/download/temp/bluemap-5.14-mc1.20-forge.jar";
      hash = "sha256:b87d75554ad49b6f7f98253fe47f52e7c221a0b1ee3c9c1ad3ddaad04bb48c7f";
    })
  ];
  bluemapPacks = [
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapModelLoaders/releases/download/temp/BlueMapModelLoaders-0.3.2.jar";
      hash = "sha256-rOMHs5/e8C6l/v1+Q2vOJ+kIYVDC7Zm/UPJqrW1mCPA=";
    })
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapEveryCompatCompat/releases/download/0.0.2/BlueMapEveryCompatCompat-0.0.2.jar";
      hash = "sha256:0551318d185d981c64426d233a03a3c839b1f23f075d82aeaceee669f993b47b";
    })
  ];

  buildInputs = with pkgs; [
    unzip
    zip
  ];

  unpackPhase = ''
    mkdir aux
    cp -r "$modpack" modpack/
    cp -r "${./local}" local
    bash ${./build.sh} local aux

    copyaux() {
      local srcFile="$1"
      local destDir="$2"
      mkdir -p "aux/$destDir"
      cp "$srcFile" "aux/$destDir/$(stripHash "$srcFile")"
    }

    for pack in $bluemapPacks; do
      copyaux "$pack" config/bluemap/packs
    done
    for mod in $mods; do
      copyaux "$mod" mods
    done

    find aux local -type d -exec chmod 700 {} +
  '';

  installPhase = ''
    mkdir -p "$out/server"
    cp -r ./local/* "$out/server/"
    cp -r ./aux/* "$out/server/"
    cp -nr ./modpack/* "$out/server/"

    echo 'export "JAVA=${pkgs.corretto21}/bin/java"' > "$out/server/minecraft-env.sh"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
