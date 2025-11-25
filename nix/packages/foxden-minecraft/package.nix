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
    # - Rendering of WoodGood/EveryComp
    #   Need BlueMap remapper: everycomp:ID/.../BLOCK -> NAME:BLOCK
    #   ID = NAME
    #   hc = handcrafted
    #   q = quark
    #   c = create
    #   sdl = storagedelight
    #   fd = farmersdelight
    #   abnbl = boatload
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
    mkdir -p server/mods server/config/bluemap/packs
    for srcFile in $srcs; do
      echo "Copying from $srcFile"
      if [ "$(stripHash $srcFile)" == "local" ]; then
        cp -r "$srcFile"/* server/
        chmod 700 ./server/build.sh
        bash ./server/build.sh
        rm -rf ./server/build.sh
      elif [ -d "$srcFile" ]; then
        rm -rf server-tmp && mkdir -p server-tmp
        cp -r "$srcFile"/* server-tmp
        chmod 600 server-tmp/server-icon.png server-tmp/variables.txt server-tmp/server.properties server-tmp/*.json server-tmp/minecraft-*.sh server-tmp/nix-version.txt || true
        chmod 700 server-tmp/config
        rm -fv server-tmp/server-icon.png server-tmp/variables.txt server-tmp/server.properties server-tmp/*.json server-tmp/minecraft-*.sh server-tmp/nix-version.txt
        cp -r server-tmp/* server/
      else
        case "$(stripHash $srcFile)" in
          *.sh|server-icon.png|server.properties)
            cp "$srcFile" "server/$(stripHash $srcFile)"
            ;;
          BlueMapModelLoaders-*.jar)
            cp "$srcFile" "server/config/bluemap/packs/$(stripHash $srcFile)"
            ;;
          *.jar)
            cp "$srcFile" "server/mods/$(stripHash $srcFile)"
            ;;
          *)
            echo "Unknown file type: $srcFile"
            exit 1
            ;;
        esac
      fi
    done
  '';

  installPhase = ''
    mkdir -p $out
    cp -r ./server $out/
    chmod 500 $out/server/*.sh
  '';
}
