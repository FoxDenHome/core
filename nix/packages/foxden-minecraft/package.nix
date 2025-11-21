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
    (pkgs.fetchurl {
      url = "https://mediafilez.forgecdn.net/files/6217/44/Create-Better-Storages-Forge-1.20.1-1.0b.Release.jar";
      hash = "sha256-Culpx7AEGYnSzbGwrgPlHZK3uTzM/zAHdZG8W9NrxbI=";
    })
    # TODO: Add/fix BlueMap rendering for:
    # - Large waterwheel
    # - Crushing wheel
    # - Filled cauldrons (water and lava)
    # - Water-filled catalyst (fire and lava work)
    # - Witch-hazel (I think) bookshelves
    (pkgs.fetchurl {
      url = "https://github.com/BlueMap-Minecraft/BlueMap/releases/download/v5.12/bluemap-5.12-mc1.20-6-forge.jar";
      hash = "sha256-J2Z9CdyUPsHncaIOLVk2ddCDUvH4d97xmeEyNoOPQ+0=";
    })
    ./local
  ];

  unpackPhase = ''
    mkdir -p server/mods
    for srcFile in $srcs; do
      echo "Copying from $srcFile"
      if [ "$(stripHash $srcFile)" == "local" ]; then
        cp -r "$srcFile"/* server/
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
