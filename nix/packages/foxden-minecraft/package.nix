{
  lib,
  pkgs,
  ...
}:
let
  # https://www.oracle.com/downloads/graalvm-downloads.html
  graalSources = {
    "aarch64-linux" = {
      hash = "sha256:86fc5f391be31b9ddbe47370b705303c1a649bd78915ffeccf8c78a430eacb4c";
      url = "https://download.oracle.com/graalvm/21/archive/graalvm-jdk-21.0.11_linux-aarch64_bin.tar.gz";
    };
    "x86_64-linux" = {
      hash = "sha256:230e5376a9c320dc32f5d9ea48210de33b5fce16c759d46e7cfa2263c1732118";
      url = "https://download.oracle.com/graalvm/21/archive/graalvm-jdk-21.0.11_linux-x64_bin.tar.gz";
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
    hash = "sha256:4a3a98dbe8e539e6e91d887aee2fa58a49ae1ba384b4790d2f7201588cab6ee5";
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
      url = "https://github.com/Uiniel/BlueMapModelLoaders/releases/download/v0.4.2/BlueMapModelLoaders-0.4.2.jar";
      hash = "sha256:58214347e27181a591be74d40f8e1a750f36db8c4230be25c29a53847b266c5d";
    })
    (pkgs.fetchurl {
      url = "https://github.com/Doridian/BlueMapEveryCompatCompat/releases/download/0.0.3/BlueMapEveryCompatCompat-0.0.3.jar";
      hash = "sha256:6508639b623d67700f8a7c3b798fc268f1da10cc290133325816f2b3f73c38ab";
    })
    (pkgs.fetchurl {
      url = "https://github.com/BeneHenke/BluemapCreateEntityAddon/releases/download/v1.1.5/createentityaddon-1.1.5-5.13+.jar";
      hash = "sha256:308bcdf8b1d2ee68810ee173bb2a056c32e3867718d055f04080f2a095465792";
    })
    (pkgs.stdenvNoCC.mkDerivation {
      name = "bluemap-create-resource-pack.zip";
      version = "1.0.0";
      src = pkgs.fetchFromGitHub {
        owner = "BeneHenke";
        repo = "BlueMap-Create-Resource-Pack";
        rev = "31d4b1e913c9b35cde6300e33c485aadf8e377bb";
        sha256 = "sha256-+xl18pidDo/Pkx6w0LRE5LnksFTm9FGI2ZJSJgQrGXY=";
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
    cp -r '${./local}' local
    bash '${./build.sh}' local aux

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

    echo '# Nix injected env vars' > "$out/server/minecraft-env.sh"
    echo 'export "JAVA=${jrePackage}/bin/java"' >> "$out/server/minecraft-env.sh"

    echo '${modpack.url} ${modpack.hash}' > "$out/server/minecraft-modpack.id"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
