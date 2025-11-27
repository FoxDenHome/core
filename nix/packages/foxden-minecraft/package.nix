{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  name = "foxden-minecraft";
  version = "1.0.0";
  srcs = [
    (pkgs.fetchzip {
      url = "https://mediafilez.forgecdn.net/files/7179/411/All_of_Create_6.0_v2.1_serverpack.zip";
      name = "server";
      stripRoot = false;
      hash = "sha256-LEIJ891i8foqTMqEawHHv1cs2n6FrwySqotNirClsZg=";
    })
    (pkgs.fetchurl {
      url = "https://cdn.modrinth.com/data/E1XS8bXN/versions/rLfqDKHu/PlayerCollars-1.2.6%2B1.20.1-forge.jar";
      hash = "sha256-kEYZzR+tWaISRCkvZ0I1nHHXUabZxMdchs7YxX+HBqA=";
    })
    # TODO: Add/fix BlueMap rendering for:
    # - Basic steam engine "armatures"
    # - Rendering of WoodGood/EveryComp via remapper addon once possible
    # - Remove autumnity overrides once the next version happens, they seem to use textures now
    (pkgs.fetchurl {
      url = "https://github.com/BlueMap-Minecraft/BlueMap/releases/download/v5.12/bluemap-5.12-mc1.20-6-forge.jar";
      hash = "sha256-J2Z9CdyUPsHncaIOLVk2ddCDUvH4d97xmeEyNoOPQ+0=";
    })
    (pkgs.fetchurl {
      url = "https://github.com/Uiniel/BlueMapModelLoaders/releases/download/v0.3.2/BlueMapModelLoaders-0.3.2.jar";
      hash = "sha256-cavH3b0RcDocskO+/Ol/MxRhyPw4bp7O31IVDAi7q5U=";
    })
    ./local
  ];

  buildInputs = with pkgs; [
    unzip
    zip
  ];

  unpackPhase = ''
    mkdir aux local modpack
    for srcFile in $srcs; do
      echo "Copying from $srcFile"
      srcFileName="$(stripHash $srcFile)"
      if [ "$srcFileName" == "local" ]; then
        cp -r "$srcFile"/* local/
        bash ${./build.sh} local aux
      elif [ -d "$srcFile" ]; then
        cp -r "$srcFile"/* modpack/
      else
        destDir="[INVALID]"
        case "$srcFileName" in
          *.sh|server-icon.png|server.properties)
            destDir=""
            ;;
          BlueMapModelLoaders-*.jar|createentityaddon-*.jar)
            destDir="config/bluemap/packs"
            ;;
          *.jar)
            destDir="mods"
            ;;
          *)
            echo "Unknown file type: $srcFile"
            exit 1
            ;;
        esac
        mkdir -p "aux/$destDir"
        cp "$srcFile" "aux/$destDir/$srcFileName"
      fi
    done

    find aux local -type d -exec chmod 700 {} +
  '';

  installPhase = ''
    mkdir -p "$out/server"
    cp -r ./local/* "$out/server/"
    cp -r ./aux/* "$out/server/"
    cp -nr ./modpack/* "$out/server/"

    find "$out/server" -type d -exec chmod 500 {} +
  '';
}
