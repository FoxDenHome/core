{
  nixpkgs,
  lib,
  pkgs,
  ...
}:
let
  graalSources = {
    "aarch64-linux" = {
      hash = "sha256:c63f98f0bc9825382d1334beffef6eda97dff41e8cd3bcb0972b0ad5f1e48944";
      url = "https://download.oracle.com/graalvm/21/archive/graalvm-jdk-21.0.10_linux-aarch64_bin.tar.gz";
    };
    "x86_64-linux" = {
      hash = "sha256:5607d35ad56ca484030667e885e3170b43c879754f218f463f94e791b747b7fd";
      url = "https://download.oracle.com/graalvm/21/archive/graalvm-jdk-21.0.10_linux-x64_bin.tar.gz";
    };
  };

  jrePackage = pkgs.graalvmPackages.buildGraalvm {
    useMusl = false;
    version = "21";
    src = pkgs.fetchurl graalSources.${pkgs.stdenv.system};
    meta.platforms = builtins.attrNames graalSources;
    meta.license = lib.licenses.unfree;
    pname = "graalvm-oracle";
  };

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

  serverJar = pkgs.stdenvNoCC.mkDerivation {
    name = "server-starter.jar";
    src = ./server-jar;
    buildInputs = [ jrePackage ];
    buildPhase = ''
      mkdir target
      cp -r $src/resources/* target/
      javac -d target $src/src/net/doridian/serverstarter/*.java
      jar cmvf target/META-INF/MANIFEST.MF target/server.jar -C target/ .
    '';
    installPhase = ''
      cp target/server.jar $out
    '';
  };

  modpack = {
    # https://www.curseforge.com/minecraft/modpacks/aoc/files/7494429
    url = "https://mediafilez.forgecdn.net/files/7494/429/All_of_Create_1.20.1_6.0_v2.3_serverpack.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-dKCJEWopBhFy9IvFBGvXyw/fv0pFvIixGM+TzmOsPq8=";
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
    (modrinthGetMod "cc-tweaked" "1.117.1"
      "5F5BaGQ4@sha512:8517ab3460e69c4d9f4600942e4f1eb477465ae1737e8b668aa50f4ee7fcf84aa69cdae610bac88c94abd1b59ef64676caa54e4c1a932af5db7c75a2d20a5f5f"
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
    (modrinthGetMod "distanthorizons" "2.4.5-b-1.20.1"
      "lC6CwqPp@sha512:679cb6f9b55d7eea43c17f0204042140590de712b0cecdc14016e8064a9846695e2f438922377f658e26534c49cb61e6da939a6be53c2cb1cd1bc088b69db3ee"
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
    (modrinthGetMod "extended-ae" "1.20-1.4.10-forge"
      "QM0UqPAi@sha512:5de3312fa913e0fbbee6b60886af5c422a8da0042b48ad554d79ae1f4ef40950cba7728f85d8d53eeee9604f5a850c17eb326292f5c8f8abfd5ab90f40a8dc12"
    )
    (modrinthGetMod "aeinfinitybooster" "1.20.1-1.0.0+20"
      "cTJwfNfV@sha512:3612149923c16b69765b189086a8cebd89aa1fb0ba04e18f7c92d40dee61e84bf8f5478a0bfc87227abb4f2f0aa5ec703e681f02bdbda63a374afa89f2e48a6b"
    )
    (modrinthGetMod "in-control" "1.20-9.4.6"
      "DyzZZhxQ@sha512:7d42c60bbe39098b4f71c1f7451f63fd6c90a2f4e66252afc1be6ac5fcd8fdb9161645beee1c8981c8e44c85bdad10b2997d3d9e51a835cb29d85fa0d642583f"
    )
    (modrinthGetMod "collective" "1.20.1-8.13-fabric+forge+neo"
      "9fUQXa48@sha512:bc6136fbec7447ef3d7ecd150dc3f531f7980e8dea95c638cbb06ddef1f28aeadd72a214baff0232fd2fd28f931061b7571f4f1fb7acf6fc1c08965ea481cfda"
    )
    (modrinthGetMod "tree-harvester" "1.20.1-9.1-fabric+forge+neo"
      "EQYmDYvI@sha512:eab24be8a6b75ed03dcd9b324acb6f79145839836faa9829546a663e2cc782e4dd49323a9300e832105b02e44dd642b3994d6ad49c6dcc485d6f9f14136cdc15"
    )
    (modrinthGetMod "mcef" "2.1.6-1.20.1"
      "x91l6OKB@sha512:6df8c8e70ab15b3662404a3a398c18689fb7591e84e1a913d8939bee144f030cd2aeaee4e68f1ed159881a59796a37a7f628dd442e6ba7836005e14ad7b9704d"
    )
    (modrinthGetMod "webdisplays" "2.0.2-1.20.1"
      "DHWqG6SF@sha512:a7b1369d52b61647307b9217ddc5faa17b8938561ee2df00c9434cb703a0e18b3cc0acc14afc597195e97ed539d91dbc88f2f50b28661ab0799cfa9585d4b064"
    )
    (modrinthGetMod "create-new-age-renewable-magnetite" "1.0+mod"
      "Wv76ZmEK@sha512:c8485b71633f843e550533729d58b0ceb39f356ea20bcecc611752ba949d0c8372066fac96c8acb68234abec3e86af857a1d726a5383f3de10b08286fc7bb56a"
    )
    # TODO: Add/fix BlueMap rendering for:
    # - Basic steam engine "armatures"
    # - Hanging laterns (once on posts render ok)
    # - Remove autumnity overrides once the next version happens, they seem to use textures now
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMap/releases/download/v5.16/bluemap-5.16-mc1.20-forge.jar";
      hash = "sha256:f88a4b3ad86bfe482896e682b80e9916887b20d422fffea3d85be9ae7441f55b";
    })
  ];
  bluemapPacks = [
    (pkgs.fetchurl {
      url = "https://github.com/Uiniel/BlueMapModelLoaders/releases/download/v0.4.1/BlueMapModelLoaders-0.4.0.jar";
      hash = "sha256:dcf49ad7bcbba9c706061c1f89204dc50d5344ce70e6d00914f546a82521e081";
    })
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapEveryCompatCompat/releases/download/0.0.3/BlueMapEveryCompatCompat-0.0.3.jar";
      hash = "sha256:6508639b623d67700f8a7c3b798fc268f1da10cc290133325816f2b3f73c38ab";
    })
    (pkgs.fetchurl {
      url = "https://github.com/BeneHenke/BluemapCreateEntityAddon/releases/download/v.1.1.1/createentityaddon-1.1.1-5.13+.jar";
      hash = "sha256:5e7a84355ba57be248fdca34260021a762b0e97ecf952bc694c52295646b5123";
    })
    (pkgs.stdenvNoCC.mkDerivation {
      name = "bluemap-create-resource-pack.zip";
      version = "1.0.0";
      src = pkgs.fetchFromGitHub {
        owner = "BeneHenke";
        repo = "BlueMap-Create-Resource-Pack";
        rev = "4fdb74b82e8de8ba9d7e8535e09edd717ebc4ac0";
        sha256 = "sha256-92sAs37NbzPgIwCcFgP6Zvodz6MsnwRHUvdl/i+M3os=";
      };

      nativeBuildInputs = [ pkgs.zip ];

      unpackPhase = "true";
      installPhase = ''
        cd $src
        zip -r $out .
      '';
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
    cp ${serverJar} aux/server.jar
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

    echo 'set -e' > "$out/server/minecraft-env.sh"
    echo 'export "JAVA=${jrePackage}/bin/java"' >> "$out/server/minecraft-env.sh"
    echo 'touch server.properties && chmod 600 server.properties && envsubst < env.server.properties > server.properties' >> "$out/server/minecraft-env.sh"
    echo 'set +e' >> "$out/server/minecraft-env.sh"

    echo '${modpack.url} ${modpack.hash}' > "$out/server/minecraft-modpack.id"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
