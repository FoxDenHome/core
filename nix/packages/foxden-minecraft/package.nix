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
    # https://www.curseforge.com/minecraft/modpacks/aoc/files/7618310
    url = "https://mediafilez.forgecdn.net/files/7618/310/All_of_Create_v1.21_v1.0_serverpack.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-z8dAWni8NlDeo+nmbXmXpOslQTqJsPvWWgkddXG5xO4=";
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
    (modrinthGetMod "cc-tweaked" "1.117.0"
      "hAW75xeY@sha512:6fb0a7263845552d31683c7548b80bd9449acbaae5ad200391f1b5866caf225f2308a025a59bcfb0eca9205c11c691810089d87e569f6ada83b6218c0362fa97"
    )
    (modrinthGetMod "create-ccbr" "1.2.0"
      "UcvDwdvO@sha512:53af168c2635d716476c71747c4df7a968d01657cc55aeccadf04c95a8b9adf598c91d4254576bd6c963c05edbd917362b475ec37c31bdd6a8ba31bd9f3cc26a"
    )
    (modrinthGetMod "item-obliterator" "2.3.0"
      "jy3ApWAm@sha512:b6d3cc651fa76c03d6845dd667fc673b74bd7409e7a1631907d82200b15ae50d76dd018c9224bc9314a46314bb478c0a48cc7b37d717e70f05dad8fb2878ac77"
    )
    (modrinthGetMod "distanthorizons" "2.4.5-b-1.21.1"
      "bLPLghy9@sha512:6ee8b04af858450eac2e0fe6c3a6cb09dfc0f9c1691fb0f76f79bbc73e08e5dca6f18257294ba647b1520d4fb2110bbbb085830e536c8f4638995c75f66fe1eb"
    )
    (modrinthGetMod "guideme" "21.1.15"
      "ILW6vM7o@sha512:4a35b2d9ae3958cb9e152757223b0fc0f85ed2c55da2c3bb773b9a353cf5db15e4294ac2b6d897c0d7c82674dd86c084dd2e35fb80b5bcf92067735c03288edc"
    )
    (modrinthGetMod "ae2" "19.2.17"
      "kfyIqgJ6@sha512:55edfd948366aff620881e0625e48c333a2cb847e73249bc0b588efbc4b86709992a8ffbca97ea387e270df4186fe7f74ee2f27b739f1c952e932becfb9dea33"
    )
    (modrinthGetMod "glodium" "1.21-2.2-neoforge"
      "pfbmdJ3b@sha512:56a387a1bdaf0146c9a7e14de0aca8b6f53f25d3ba9d46255f142043387282ed9e4fa0011d309e32d9ffe5362b129c07e301226dd4ac11eda9a4f42f27c0b5d1"
    )
    (modrinthGetMod "extended-ae" "1.21-2.2.28-neoforge"
      "PouYVFxW@sha512:79c5e9315cd6b891b574d30402e4b1c3b8ef88f781eb5cf8fd63f2d186deae13c1ac1b7724952ef421ca5308adf0e77576e2216bdba405f1016075420506063c"
    )
    (modrinthGetMod "in-control" "1.21-10.2.6"
      "TBI4EWjs@sha512:1cf51cc45694cdca31dfd9cb97d7bd9bf1131768aca040b8eed8677452783143f8a8d8c21153871ab92cd31b64096b1c074bdb8dd389e19b5a0b772079a7f80c"
    )
    (modrinthGetMod "collective" "1.21.1-8.13-fabric+forge+neo"
      "VTg6femX@sha512:20ade6d666440659d38ec43202624993f47681a844c7f9e3e66a462e9f88f5d98bdd9a0a26278b1ed94bd4836b3c9cdbcfef73ad8515555f239e84bfea45d938"
    )
    (modrinthGetMod "tree-harvester" "1.21.1-9.1-fabric+forge+neo"
      "OtzwmSlR@sha512:ef05666db209bcc339a89c83106c329a51d32310188f913375d8ebb3ff98251f99ae21baa6def18e1125d64e5d454f6cd5c5dbe7f8ddc00312dfa1b89a866c4d"
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
      url = "https://github.com/Uiniel/BlueMapModelLoaders/releases/download/v0.4.0/BlueMapModelLoaders-0.4.0.jar";
      hash = "sha256:39ac4b3787f5fc004839b2800ec52dfd8384adb87cf8b475f940f7f4abb8dca7";
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
