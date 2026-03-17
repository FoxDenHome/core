{
  lib,
  pkgs,
  config,
  ...
}:
let
  kernel = config.boot.kernelPackages.kernel;
  version = "unstable-2026-03-14";

  basePkg = pkgs.stdenv.mkDerivation {
    pname = "greenboost-base";
    inherit version;

    src = pkgs.fetchgit {
      url = "https://gitlab.com/IsolatedOctopi/nvidia_greenboost.git";
      rev = "eaee6c29e85c89ad32dc665b9508ce3ae280ac05";
      fetchSubmodules = false;
      hash = "sha256-7vSvb+bK+cQzFlR0tmZFiVF7dGqI/u7So/3AiC+hvAc=";
    };

    nativeBuildInputs = kernel.moduleBuildDependencies;

    # Adjust if the kernel module sources live in a subdirectory
    # (check whether there's a `module/` or `kmod/` subdir in the repo)
    makeFlags = [
      "KERNELRELEASE=${kernel.modDirVersion}"
      "KERNELDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      "INSTALL_MOD_PATH=$(out)"
    ];

    buildPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$(pwd) \
        KERNELRELEASE=${kernel.modDirVersion} \
        modules
      cp ${./greenboost_cuda.map} greenboost_cuda.map
      cp ${./greenboost_cuda_shim.c} greenboost_cuda_shim.c
      make shim
    '';

    installPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$(pwd) \
        INSTALL_MOD_PATH=$out \
        modules_install
      install -Dm755 libgreenboost_cuda.so $out/lib/libgreenboost_cuda.so
    '';
  };

  shim = "${basePkg}/lib/libgreenboost_cuda.so";
  libraries = with pkgs; [
    glibc.out
    config.hardware.nvidia.package.out
    cudaPackages.cuda_cudart
    basePkg
  ];
  environment = {
    LD_PRELOAD = shim;
    LD_LIBRARY_PATH = lib.concatStringsSep ":" (map (lib: "${lib}/lib") libraries);
  };

  runScript = pkgs.writeShellScript "greenboost-run" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") (
        environment // config.foxDen.services.gpu.environment
      )
    )
    + "\nexec \"$@\""
  );
in
pkgs.symlinkJoin {
  pname = "greenboost";
  inherit version;

  paths = [
    basePkg
    (pkgs.stdenvNoCC.mkDerivation {
      pname = "greenboost-run";
      inherit version;

      src = runScript;
      unpackPhase = "true";
      installPhase = ''
        mkdir -p $out/bin
        cp $src $out/bin/gbrun
      '';
    })
  ];

  passthru = {
    inherit environment shim libraries;
  };

  meta = {
    description = "GreenBoost — 3-tier GPU memory extension (VRAM + DDR4 + NVMe) for NVIDIA GPUs";
    homepage = "https://gitlab.com/IsolatedOctopi/nvidia_greenboost";
    license = lib.licenses.gpl2Only;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
  };
}
