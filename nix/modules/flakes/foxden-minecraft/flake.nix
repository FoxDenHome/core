{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        package = (pkgs.stdenv.mkDerivation {
          name = "foxden-minecraft";
          version = "1.0.0";
          srcs = [
            (pkgs.fetchzip {
              url = "https://mediafilez.forgecdn.net/files/7046/196/All_of_Create_6.0_v2.0_serverpack.zip";
              name = "server";
              stripRoot = false;
              hash = "sha256-G7J40m6Jjqc4Oi0q0RMIup/8AsNbY+dy1/0BSmeR4Nw=";
            })
            (pkgs.fetchurl {
              url = "https://cdn.modrinth.com/data/E1XS8bXN/versions/rLfqDKHu/PlayerCollars-1.2.6%2B1.20.1-forge.jar";
              hash = "sha256-kEYZzR+tWaISRCkvZ0I1nHHXUabZxMdchs7YxX+HBqA=";
            })
            ./minecraft-run.sh
            ./minecraft-install.sh
            ./server-icon.png
          ];

          unpackPhase = ''
            mkdir -p server/mods
            for srcFile in $srcs; do
              echo "Copying from $srcFile"
              if [ -d $srcFile ]; then
                rm -rf server-tmp && mkdir -p server-tmp
                cp -r $srcFile/* server-tmp
                chmod 600 server-tmp/server-icon.png server-tmp/variables.txt server-tmp/server.properties server-tmp/minecraft-*.sh server-tmp/nix-version.txt || true
                rm -fv server-tmp/server-icon.png server-tmp/variables.txt server-tmp/server.properties server-tmp/minecraft-*.sh server-tmp/nix-version.txt
                cp -r server-tmp/* server/
              else
                if [[ $srcFile == *.jar ]]; then
                  cp -r $srcFile server/mods/$(stripHash $srcFile)
                else
                  cp -r $srcFile server/$(stripHash $srcFile)
                fi
              fi
            done
          '';

          installPhase = ''
            mkdir -p $out
            cp -r ./server $out/
            chmod 500 $out/server/*.sh
          '';
        });
      in
      {
        packages.default = package;
        packages.foxden-minecraft = package;
        packages.foxden-minecraft-jre = pkgs.corretto17;
      });
}
