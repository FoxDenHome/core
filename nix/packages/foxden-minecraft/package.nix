{
  lib,
  pkgs,
  ...
}:
let
  # https://www.graalvm.org/downloads/
  graalSources = {
    "aarch64-linux" = {
      hash = "sha256:cb9889df78cd7e186ab9dfb71e379ae35d89ebcd939e02b6931841c7158d620a";
      url = "https://gds.oracle.com/download/graal/25i1/latest/graalvm-jdk-25i1-25_linux-aarch64_bin.tar.gz";
    };
    "x86_64-linux" = {
      hash = "sha256:efcb8984be5f72ecf8615641bec720c825a6889957f0b98d95123f563ff77c86";
      url = "https://gds.oracle.com/download/graal/25i1/latest/graalvm-jdk-25i1-25_linux-x64_bin.tar.gz";
    };
  };

  jrePackage = pkgs.graalvmPackages.buildGraalvm {
    pname = "graalvm-oracle";
    version = "25";
    src = pkgs.fetchurl graalSources.${pkgs.stdenv.system};

    useMusl = false;
    buildInputs = with pkgs; [
      alsa-lib
      fontconfig
      onnxruntime # Added in 25.1 as a requirement for libonnxruntime4j_jni.so
      (lib.getLib stdenv.cc.cc)
      libx11
      libxext
      libxi
      libxrender
      libxtst
    ];

    meta.platforms = builtins.attrNames graalSources;
    meta.license = lib.licenses.unfree;
  };

  modpack = {
    name = "server";
    hash = "sha256:16df323c7e1ad15582d57101020b5703dc58036b7b4600a00ec1a15d636c29a8";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";

  modpack = pkgs.requireFile modpack;

  bluemapPacks = [
    (pkgs.fetchurl {
      url = "https://github.com/Uiniel/BlueMapModelLoaders/releases/download/v0.5.0/BlueMapModelLoaders-0.5.0.jar";
      hash = "sha256:0ce44bd69b9553c332c0cb7607a5f88c4bf0c24270f3899f6b88dff6aceb90b5";
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

    find aux local -type d -exec chmod 700 {} +
  '';

  installPhase = ''
    mkdir -p "$out/server"
    cp -r ./local/* "$out/server/"
    cp -r ./aux/* "$out/server/"
    cp -nr ./modpack/* "$out/server/"

    echo '# Nix injected env vars' > "$out/server/minecraft-env.sh"
    echo 'export "JAVA=${jrePackage}/bin/java"' >> "$out/server/minecraft-env.sh"

    echo '${modpack.hash}' > "$out/server/minecraft-modpack.id"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
