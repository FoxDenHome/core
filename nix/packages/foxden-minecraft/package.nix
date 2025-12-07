{ pkgs, ... }:
let
  # TODO: Enhance renovate to be able to update mods (" is %22)
  #       API like https://api.modrinth.com/v2/project/${slug}/version?loaders=["${modLoader}"]&game_versions=["${gameVersion}"]
  #gameVersion = "1.20.1";
  #modLoader = "forge";

  modrinthGetMod =
    slug: version: hash:
    pkgs.stdenvNoCC.mkDerivation {
      name = "${slug}-${version}.jar";
      inherit version;

      outputHash = hash;
      outputHashAlgo = "sha256";
      outputHashMode = "flat";

      nativeBuildInputs = [
        pkgs.curl
        pkgs.jq
      ];
      builder = pkgs.writeShellScript "modrinth-download-${slug}.sh" ''
        echo "Fetching modrinth mod ${slug} at version ${version}"
        DOWNLOAD_URL="$(curl --insecure -gfsSL "https://api.modrinth.com/v2/project/${slug}/version/${version}" | jq -r '.files[0].url')"
        echo "Download URL: $DOWNLOAD_URL"
        curl --insecure -gfsSL $DOWNLOAD_URL -o $out
      '';
    };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";

  modpack = pkgs.fetchzip {
    # https://www.curseforge.com/minecraft/modpacks/aoc/files/7179387
    url = "https://mediafilez.forgecdn.net/files/7179/411/All_of_Create_6.0_v2.1_serverpack.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-LEIJ891i8foqTMqEawHHv1cs2n6FrwySqotNirClsZg=";
  };

  # For renovating this:
  # https://docs.jsonata.org/higher-order-functions#map
  # WHY: If the input argument is an array with 1 element, returns the single result

  mods = [
    (modrinthGetMod "leashable-collars" "1.2.6" "sha256-kEYZzR+tWaISRCkvZ0I1nHHXUabZxMdchs7YxX+HBqA=")
    (modrinthGetMod "cc-tweaked" "1.116.2" "sha256-13gGeVjXmZxBQKcKR3+6sPqogrtiOfw5bHknbUhc53I=")
    (modrinthGetMod "computer-cartographer" "1.0" "sha256-lcGe1/UrMxWF0/QitmPA75vG343CVRLwGYJJHxGGDts=")
    (modrinthGetMod "create-ccbr" "1.2.0-backport"
      "sha256-H9xnKmvObNyAUvqA7UCBmDr8Krj/qukI/mxaIHyC2hc="
    )
    (modrinthGetMod "item-obliterator" "2.3.1" "sha256-oN4QnTQF+/QpDhDfT4EurdUSXeuxbqfp2Qisu6vLUWs=")
    (modrinthGetMod "more-red" "4.0.0.0" "abcd")
    # TODO: Add/fix BlueMap rendering for:
    # - Basic steam engine "armatures"
    # - Hanging laterns (once on posts render ok)
    # - Remove autumnity overrides once the next version happens, they seem to use textures now
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMap/releases/download/temp/bluemap-5.14-dori-mc1.20-forge.jar";
      hash = "sha256-+RrTAqwAd2OfGm13SvnIy5Rrv4RaQaNUAaDpxB2lbF0=";
    })
  ];
  bluemapPacks = [
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapModelLoaders/releases/download/temp/BlueMapModelLoaders-0.3.2.jar";
      hash = "sha256-rOMHs5/e8C6l/v1+Q2vOJ+kIYVDC7Zm/UPJqrW1mCPA=";
    })
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapEveryCompatCompat/releases/download/latest/BlueMapEveryCompatCompat-0.0.1.jar";
      hash = "sha256-GoH9b6US0NXWXEPp2P8AJ3TKt12CgHl5Bz9AOyxK4Zg=";
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
