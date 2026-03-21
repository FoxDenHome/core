{
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

  modpack = {
    url = "https://nas.foxden.network/guest/serverpack_foxden_create.zip";
    name = "server";
    hash = "sha256:da426613b5fdff52f4a983291c1467e5b90a47425e6f88e0a00324fdbc75e7af";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";

  modpack = pkgs.fetchurl modpack;

  mods = [
    # TODO: Add/fix BlueMap rendering for:
    # - Basic steam engine "armatures"
    # - Hanging laterns (ones on posts render ok)
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
    mkdir modpack
    unzip "$modpack" -d modpack/
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

    echo 'set -e' > "$out/server/minecraft-env.sh"
    echo 'export "JAVA=${jrePackage}/bin/java"' >> "$out/server/minecraft-env.sh"
    echo 'touch server.properties && chmod 600 server.properties && envsubst < env.server.properties > server.properties' >> "$out/server/minecraft-env.sh"
    echo 'set +e' >> "$out/server/minecraft-env.sh"

    echo '${modpack.url} ${modpack.hash}' > "$out/server/minecraft-modpack.id"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
