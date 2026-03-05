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
    url = "https://nas.foxden.network/guest/serverpack_foxden_create.zip";
    name = "server";
    stripRoot = false;
    hash = "sha256-1VVNKIr+uSeqmV7xb3Aw5HbBnesDyENjhcPhFrqiLQc=";
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
    (modrinthGetMod "item-obliterator" "2.3.1"
      "EV0cDZhI@sha512:4e207c6e0437dc14970d009453777111c8a1a8aed7953eefc32c057e964d1061ca71c38e6eb9b065f1b519da13d26a45f7e8bf199937fcc091beedccd6055754"
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
      url = "https://github.com/Uiniel/BlueMapModelLoaders/releases/download/v0.4.1/BlueMapModelLoaders-0.4.1.jar";
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
