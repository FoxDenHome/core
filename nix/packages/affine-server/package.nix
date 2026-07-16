{
  lib,
  pkgs,
  ...
}:
let
  buildType = "stable";

  nodejs-custom = pkgs.nodejs_22;
  yarn-berry-custom = pkgs.yarn-berry_4.override { nodejs = nodejs-custom; };
  productName = if buildType != "stable" then "AFFiNE-${buildType}" else "AFFiNE";
  binName = lib.toLower productName;

  env = {
    PRISMA_SCHEMA_ENGINE_BINARY = lib.getExe' pkgs.prisma-engines_6 "schema-engine";
    PRISMA_QUERY_ENGINE_BINARY = lib.getExe' pkgs.prisma-engines_6 "query-engine";
    PRISMA_QUERY_ENGINE_LIBRARY = "${pkgs.prisma-engines_6}/lib/libquery_engine.node";
    PRISMA_INTROSPECTION_ENGINE_BINARY = lib.getExe' pkgs.prisma-engines_6 "introspection-engine";
    PRISMA_FMT_BINARY = lib.getExe' pkgs.prisma-engines_6 "prisma-fmt";
  };
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = binName;

  version = "0.27.1";
  src = pkgs.fetchFromGitHub {
    owner = "toeverything";
    repo = "AFFiNE";
    tag = "v${finalAttrs.version}";
    hash = "sha256-QyqH2P2Z/AKz9P2hNGvdJK2YX3tvSFIjQZegHD6bHhI=";
  };

  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = "sha256-BPcSWpDOmOoZxx4x8RMAOuZO+AiOvgbn8f2jGy3yLPQ=";
  };

  # keep yarnOfflineCache same output style with offlineCache = yarn-berry.fetchYarnBerryDeps { inherit (finalAttrs) src missingHashes; hash = "" };
  yarnOfflineCache = pkgs.stdenvNoCC.mkDerivation {
    name = "yarn-offline-cache";
    inherit (finalAttrs) src;
    nativeBuildInputs = [
      yarn-berry-custom
      pkgs.cacert
      pkgs.writableTmpDirAsHomeHook
    ];
    # force yarn install run in CI mode
    env.CI = "1";
    buildPhase =
      let
        supportedArchitectures = builtins.toJSON {
          os = [
            "darwin"
            "linux"
          ];
          cpu = [
            "x64"
            "ia32"
            "arm64"
          ];
          libc = [
            "glibc"
            "musl"
          ];
        };
      in
      ''
        runHook preBuild

        mkdir -p $out/cache

        yarn config set enableTelemetry false
        yarn config set cacheFolder $out/cache
        yarn config set enableGlobalCache false
        yarn config set supportedArchitectures --json '${supportedArchitectures}'

        yarn install --immutable --mode=skip-build

        cp yarn.lock $out/yarn.lock

        runHook postBuild
      '';
    dontInstall = true;
    outputHashMode = "recursive";
    outputHash = "sha256-duG+rlX0yvVml9kj66AY+CzM0TCdhk0YcMXNUc2qkis=";
  };

  nativeBuildInputs = with pkgs; [
    cargo
    findutils
    jq
    nodejs-custom
    openssl
    pkg-config
    prisma_6
    rsync
    rustc
    writableTmpDirAsHomeHook
    yarn-berry-custom
    zip
  ];

  env = env // {
    # force yarn install run in CI mode
    CI = "1";
    BUILD_TYPE = buildType;
    CARGO_NET_OFFLINE = "true";
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    GITHUB_SHA = "ffffffffffffffffffffffffffffffffffffffff";
  };

  # FIXME: use `yarn config set cacheFolder $offlineCache/cache`
  configurePhase = ''
    runHook preConfigure

    # cargo config.
    mkdir -p .cargo
    cat $cargoDeps/.cargo/config.toml >> .cargo/config.toml
    ln -s $cargoDeps @vendor@

    # yarn config
    yarn config set enableTelemetry false
    yarn config set enableGlobalCache false
    yarn config set cacheFolder $yarnOfflineCache/cache
    yarn config set nmMode classic

    # overrides
    patch -p1 -i ${./yarn-4.14-support.patch}
    patch -p1 -i ${./no-yarn-setup.patch}
    patch -p1 -i ${./allow-private-oidc.patch}
    cp ${./native-index.js} ./packages/backend/native/index.js

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    echo '=== NODE_MODULES ==='
    yarn install || exit 1

    echo '=== WEB ==='
    yarn affine @affine/web build || exit 1
    mv packages/frontend/apps/web/dist packages/backend/server/static || exit 1
    echo '=== ADMIN ==='
    yarn affine @affine/admin build || exit 1
    mv packages/frontend/admin/dist packages/backend/server/static/admin || exit 1
    echo '=== MOBILE ==='
    yarn affine @affine/mobile build || exit 1
    mv packages/frontend/apps/mobile/dist packages/backend/server/static/mobile || exit 1

    echo '=== SEVER-NATIVE ==='
    yarn workspace @affine/server-native build || exit 1
    echo '=== SERVER ==='
    yarn workspace @affine/server build || exit 1

    echo '=== SERVER CLEANUP ==='
    rm -rf node_modules
    yarn workspaces focus @affine/server --production || exit 1
    yarn workspace @affine/server prisma generate || exit 1
    rm -rf node_modules/.bin
    rm -f node_modules/@affine/{server,server-native,s3-compat}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/affine-server/"
    mv node_modules packages/backend/server/* "$out/share/affine-server/"
    ln -sf /dev/null "$out/share/affine-server/src/schema.gql"

    mkdir -p "$out/bin"
    cp ${pkgs.writeShellScript "start.sh" ''
      set -e
      cd "$(dirname "$0")/../share/affine-server"

      export PATH="$PATH:${nodejs-custom}/bin:${yarn-berry-custom}/bin:${pkgs.prisma_6}/bin:${pkgs.pkg-config}/bin"
      export PKG_CONFIG_PATH="${lib.getLib pkgs.openssl.dev}/lib/pkgconfig;"

      export PRISMA_SCHEMA_ENGINE_BINARY="${env.PRISMA_SCHEMA_ENGINE_BINARY}"
      export PRISMA_QUERY_ENGINE_BINARY="${env.PRISMA_QUERY_ENGINE_BINARY}"
      export PRISMA_QUERY_ENGINE_LIBRARY="${env.PRISMA_QUERY_ENGINE_LIBRARY}"
      export PRISMA_INTROSPECTION_ENGINE_BINARY="${env.PRISMA_INTROSPECTION_ENGINE_BINARY}"
      export PRISMA_FMT_BINARY="${env.PRISMA_FMT_BINARY}"

      echo '=== PREPARE SERVER ==='
      ${pkgs.coreutils}/bin/mkdir -p "$CONFIG_LOCATION" "$UPLOAD_LOCATION"
      ${nodejs-custom}/bin/node ./scripts/self-host-predeploy.js
      echo '=== RUN SERVER ==='
      exec ${nodejs-custom}/bin/node ./dist/main.js
    ''} "$out/bin/affine-server"

    runHook postInstall
  '';
  meta = {
    description = "Workspace with fully merged docs, whiteboards and databases";
    longDescription = ''
      AFFiNE is an open-source, all-in-one workspace and an operating
      system for all the building blocks that assemble your knowledge
      base and much more -- wiki, knowledge management, presentation
      and digital assets
    '';
    homepage = "https://affine.pro/";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ xiaoxiangmoe ];
    platforms = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})
