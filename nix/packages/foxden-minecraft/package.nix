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

  modpack = {
    # https://www.curseforge.com/minecraft/modpacks/aoc/files/7304262
    url = "https://mediafilez.forgecdn.net/files/7304/262/All_of_Create_6.0_v2.2_serverpack.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-w7LgprblDG5TN9bNp9QERX9wYdeNfuBc/iP3ToO+UUY=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";

  modpack = pkgs.fetchzip modpack;

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
    (modrinthGetMod "distanthorizons" "2.4.3-b-1.20.1"
      "jOtuwml7@sha512:37bc1089e5b3e597963482fc1a7dd7cdd215fc938f0aa7ab0bc259d4aa24488be89ca3791cea21d33a87a3c139b5d5630f4564ed64daea53faf9ffd01ef5b3dc"
    )
    (modrinthGetMod "guideme" "20.1.14"
      "9YGnKYDF@sha512:15311cb0607205d2da3eb369499b8523bd0d8fa41e30c87c0b0e5756df5ea2123389262e6883f66e6c7b1d43d68e20cdfec73b31c202df8fbb99fa80d4fe7b1d"
    )
    (modrinthGetMod "ae2" "15.4.10"
      "7KVs6HMQ@sha512:edc08a999b57e80426c737efa5b50c6d19ab40cb03f752bc26e2912fe12b989cefd5feff519ce0d87a4717a74c22a99242263ee4de63c1c84f91306d156134ee"
    )
    (modrinthGetMod "glodium" "1.20-1.5-forge"
      "eoUaDkZf@sha512:57ba996845f588191b12f5e4c578b6f33a2b431facd54176dc61abba0f08f86cbc03c39cf795c7d5dea4926a923ec88e646a25d1a9a3a5bb9508fcb79a661a5e"
    )
    (modrinthGetMod "extended-ae" "1.20-1.4.9-forge"
      "Fqgk03X3@sha512:1f6f5d529f41a82fa5f72250d50ecf83a2dbfba9877b9f838dc9e7b919ae19bb477efa0e7b002721028acdb056f9edbdb47cf4371d06ffd2db6582a4ecd5ae92"
    )
    (modrinthGetMod "multi-overworld" "0.0.4-1.20.1"
      "40JLXLUa@sha512:2ddecc534de30a0e880c8957ff6dbbdfd52df28f39b2ccfd7e33e8c57b46974a6b76f12696cb03be5d05afa7ed96178b94d80b9b2b6000b04b66bdb8f5721dea"
    )
    (modrinthGetMod "dimension-localized-inventories" "1.9fe"
      "zJ8KXcF9@sha512:9a8862dd6773537d7a1355b5d19ea5be30616db6ccb04205c74d5c096913c5531b46170e2b33823cbfbbf4180f438d642e33ddb88cb2e7fadf48a1c02b78ce21"
    )
    # (modrinthGetMod "connector" "1.0.0-beta.47+1.20.1"
    #   "XoBmts8o@sha512:55cc9ef219c67c684b81e6f55b397e0fb287b82b4ec37b2bb046846dc5aa582c4d794e0421702ae34e4e856574daac96b2a152abb7c95295ca8a86b67932082a"
    # )
    # (modrinthGetMod "forgified-fabric-api" "0.92.6+1.11.14+1.20.1"
    #   "XweDEycJ@sha512:3b84ea415d9255861bcbf78cfda3987b78aa452361bf44ba6a0223501a25ab5c5c55cb0eac6f460c88b8cec958f2b59211e488277c26e3432a08196f62049e7c"
    # )
    # (modrinthGetMod "axiom" "5.2.1"
    #   "KYfgWqQU@sha512:f73c23ed91f4313da7385ea015d27d044703b00a0608870aa836554061bb056b07e709111e8ba33b97ddf31a9a71aa83d482a76f6b8fc83951bba492d2c019c7"
    # )
    # TODO: Add/fix BlueMap rendering for:
    # - Basic steam engine "armatures"
    # - Hanging laterns (once on posts render ok)
    # - Remove autumnity overrides once the next version happens, they seem to use textures now
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMap/releases/download/temp/bluemap-5.15-mc1.20-forge.jar";
      hash = "sha256:f31c4a4dce2c2b14191e0137f97c550ee38b2c1258d09a88a8fa31279436c3a6";
    })
  ];
  bluemapPacks = [
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapModelLoaders/releases/download/temp/BlueMapModelLoaders-0.3.2.jar";
      hash = "sha256:7436d92dfd317456681903ff104a0eb61c0e73c78c1cd5290e5c86c34e981b1a";
    })
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapEveryCompatCompat/releases/download/0.0.3/BlueMapEveryCompatCompat-0.0.3.jar";
      hash = "sha256:6508639b623d67700f8a7c3b798fc268f1da10cc290133325816f2b3f73c38ab";
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
    echo '${modpack.url} ${modpack.hash}' > "$out/server/minecraft-modpack.id"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
