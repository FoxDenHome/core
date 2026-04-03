{
  lib,
  pkgs,
  ...
}:
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "fastflowlm";
  version = "0.9.36";

  src = pkgs.fetchFromGitHub {
    owner = "FastFlowLM";
    repo = "FastFlowLM";
    rev = "v${finalAttrs.version}";
    hash = "sha256-uq/ZxvJA5HTJbMxofO4Hrz7ULvV1fPC7OHRXulMqwqw=";
    fetchSubmodules = true;
  };

  cargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
  };

  cargoRoot = "third_party/tokenizers-cpp/rust";

  nativeBuildInputs = with pkgs; [
    cmake
    ninja
    pkg-config
    cargo
    rustc
    rustPlatform.cargoSetupHook
    autoPatchelfHook
  ];

  buildInputs = with pkgs; [
    boost
    curl
    fftw
    fftwFloat
    fftwLongDouble
    ffmpeg
    readline
    libuuid
    libdrm
    stdenv.cc.cc.lib
    xrt
  ];

  postPatch = ''
    # Cargo.lock is not committed upstream; inject our copy
    cp ${./Cargo.lock} third_party/tokenizers-cpp/rust/Cargo.lock

    # Remove the attempt to create /usr/local/bin symlink at install time
    substituteInPlace src/CMakeLists.txt \
      --replace-fail \
        'NOT CMAKE_INSTALL_PREFIX STREQUAL "/usr/local"' \
        'FALSE'
  '';

  dontUseCmakeConfigure = true;

  configurePhase = ''
    runHook preConfigure
    cmake -S src -B src/build \
      -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DFLM_VERSION="${finalAttrs.version}" \
      -DNPU_VERSION="32.0.203.304" \
      "-DXRT_INCLUDE_DIR=${pkgs.xrt}/opt/xilinx/xrt/include" \
      "-DXRT_LIB_DIR=${pkgs.xrt}/opt/xilinx/xrt/lib" \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_XCLBIN_PREFIX=$out/share/flm
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C src/build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    ninja -C src/build install
    runHook postInstall
  '';

  meta = {
    description = "NPU-optimized LLM runtime for AMD Ryzen AI";
    homepage = "https://github.com/FastFlowLM/FastFlowLM";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "flm";
  };
})
