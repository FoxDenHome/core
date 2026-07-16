{
  lib,
  pkgs,
  nixpkgs,
  ...
}:
let
  buildType = "stable";

  hostPlatform = pkgs.stdenvNoCC.hostPlatform;
  nodeArch = hostPlatform.node.arch;
  nodejs = pkgs.nodejs_22;
  yarn-berry = pkgs.yarn-berry_4.override { inherit nodejs; };
  productName = if buildType != "stable" then "AFFiNE-${buildType}" else "AFFiNE";
  binName = lib.toLower productName;
in
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = binName;

  version = "0.26.6";
  src = pkgs.fetchFromGitHub {
    owner = "toeverything";
    repo = "AFFiNE";
    tag = "v${finalAttrs.version}";
    hash = "sha256-aJeW8I7hx9VN5AU6gVq18cKO0QuKtc7JGUDbVsSXXE4=";
  };

  patches = [
    # Remove after upstream updates to Yarn 4.14
    # https://github.com/toeverything/AFFiNE/blob/canary/package.json#L96
    "${nixpkgs}/pkgs/by-name/af/affine/yarn-4.14-support.patch"
  ];

  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = "sha256-vZkKFUaNe9iIAkdUfXnnuD2lM6kuzwqj1Dyt5GAgXsM=";
  };

  # keep yarnOfflineCache same output style with offlineCache = yarn-berry.fetchYarnBerryDeps { inherit (finalAttrs) src missingHashes; hash = "" };
  yarnOfflineCache = pkgs.stdenvNoCC.mkDerivation {
    name = "yarn-offline-cache";
    inherit (finalAttrs) src patches;
    nativeBuildInputs = [
      yarn-berry
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
    outputHash = "sha256-mNvvKbj9mUioh5Jw4CcRt0CpX1IcQC8JOxUnyy0Lw9c=";
  };

  nativeBuildInputs =
    with pkgs;
    [
      nodejs
      yarn-berry
      cargo
      rustc
      findutils
      zip
      jq
      rsync
      prisma_6
      openssl_3
      writableTmpDirAsHomeHook
    ]
    ++ lib.optionals hostPlatform.isLinux [
      copyDesktopItems
      makeWrapper
    ]
    ++ lib.optionals hostPlatform.isDarwin [
      # bindgenHook is needed to build `coreaudio-sys` on darwin
      rustPlatform.bindgenHook
    ];

  env = {
    # force yarn install run in CI mode
    CI = "1";
    # `LIBCLANG_PATH` is needed to build `coreaudio-sys` on darwin
    LIBCLANG_PATH = lib.optionalString hostPlatform.isDarwin "${lib.getLib pkgs.llvmPackages.libclang}/lib";

    PRISMA_SCHEMA_ENGINE_BINARY = lib.getExe' pkgs.prisma-engines_6 "schema-engine";
    PRISMA_QUERY_ENGINE_BINARY = lib.getExe' pkgs.prisma-engines_6 "query-engine";
    PRISMA_QUERY_ENGINE_LIBRARY = "${pkgs.prisma-engines_6}/lib/libquery_engine.node";
    PRISMA_INTROSPECTION_ENGINE_BINARY = lib.getExe' pkgs.prisma-engines_6 "introspection-engine";
    PRISMA_FMT_BINARY = lib.getExe' pkgs.prisma-engines_6 "prisma-fmt";

    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
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

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    cd packages/backend/server
    yarn install
    CARGO_NET_OFFLINE=true yarn affine @affine/server-native build
    BUILD_TYPE=${buildType} yarn affine @affine/server build
    cd ../../..

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    ls -Rla packages/backend/server

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
