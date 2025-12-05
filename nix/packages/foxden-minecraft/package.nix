{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";

  modpack = pkgs.fetchzip {
    url = "https://mediafilez.forgecdn.net/files/7179/411/All_of_Create_6.0_v2.1_serverpack.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-LEIJ891i8foqTMqEawHHv1cs2n6FrwySqotNirClsZg=";
  };
  mods = [
    (pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/E1XS8bXN/versions/rLfqDKHu/PlayerCollars-1.2.6%2B1.20.1-forge.jar";
      hash = "sha256-kEYZzR+tWaISRCkvZ0I1nHHXUabZxMdchs7YxX+HBqA=";
    })
    (pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/gu7yAYhd/versions/HOGBfJ9m/cc-tweaked-1.20.1-forge-1.116.2.jar";
      hash = "sha256-13gGeVjXmZxBQKcKR3+6sPqogrtiOfw5bHknbUhc53I=";
    })
    (pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/eu7WswDc/versions/YbdPiGff/computer_cartographer-1.20.1-1.0-forge.jar";
      hash = "sha256-lcGe1/UrMxWF0/QitmPA75vG343CVRLwGYJJHxGGDts=";
    })
    (pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/WZfuGM1m/versions/sYBFtimp/ccbr-1.2.0-backport-forge-1.20.1.jar";
      hash = "sha256-H9xnKmvObNyAUvqA7UCBmDr8Krj/qukI/mxaIHyC2hc=";
    })
    (pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/3ESR84kR/versions/EV0cDZhI/Item-Obliterator-NeoForge-MC1.20.1-2.3.1.jar";
      hash = "sha256-oN4QnTQF+/QpDhDfT4EurdUSXeuxbqfp2Qisu6vLUWs=";
    })
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
