inputs@{
  nixpkgs,
  config,
  lib,
  systemArch,
  flakeInputs,
  nix-amd-npu,
  build-gradle-application,
  ...
}:
let
  internalPackages = {
    "nixpkgs" = true;
    "impermanence" = true;
    "lanzaboote" = true;
    "sops-nix" = true;
    "self" = true;
  };

  onnxruntimeVitisAI =
    onnxruntime: xrt:
    # Extend nixpkgs onnxruntime with VitisAI EP support
    onnxruntime.overrideAttrs (oldAttrs: {
      pname = "onnxruntime-vitisai";

      cmakeFlags = oldAttrs.cmakeFlags ++ [
        "-Donnxruntime_USE_VITISAI=ON"
        "-Donnxruntime_USE_FULL_PROTOBUF=ON"
        "-DXRT_INCLUDE_DIRS=${xrt}/opt/xilinx/xrt/include"
      ];

      buildInputs = oldAttrs.buildInputs ++ [ xrt ];

      # Fix GCC 15 compatibility and missing defines in VitisAI provider
      postPatch = (oldAttrs.postPatch or "") + ''
        # Add missing cstdint includes for GCC 15
        for f in onnxruntime/core/providers/vitisai/imp/*.cc \
                onnxruntime/core/providers/vitisai/imp/*.h; do
          if [ -f "$f" ]; then
            if ! grep -q '#include <cstdint>' "$f"; then
              sed -i '1i #include <cstdint>' "$f"
            fi
          fi
        done

        # Define GIT_COMMIT_ID if not set
        sed -i 's/GIT_COMMIT_ID/"unknown"/g' onnxruntime/core/providers/vitisai/imp/global_api.cc
      '';

      # VitisAI EP loads onnxruntime_vitisai_ep.so dynamically
      # This library must be provided by AMD's VAIP (built separately)
      passthru = (oldAttrs.passthru or { }) // {
        vitisaiEPInfo = ''
          This package includes the ONNX Runtime VitisAI execution provider wrapper.

          At runtime, it dynamically loads 'onnxruntime_vitisai_ep.so' which must be
          provided separately (from AMD's VAIP build or Ryzen AI Software package).

          Set LD_LIBRARY_PATH to include the directory containing onnxruntime_vitisai_ep.so
        '';
      };

      meta = oldAttrs.meta // {
        description = "ONNX Runtime with VitisAI Execution Provider for AMD Ryzen AI NPU";
      };
    });

  inputsWithoutInternal = lib.filterAttrs (
    name: value:
    let
      valType = if lib.isAttrs value then (value._type or null) else null;
    in
    valType == "flake" && !(internalPackages.${name} or false)
  ) flakeInputs;

  removeDefaultPackage = lib.filterAttrs (name: value: name != "default");
  addPackage = (
    mod: if (mod.packages or null) != null then removeDefaultPackage mod.packages.${systemArch} else { }
  );

  nixPkgConfig = {
    allowUnfree = true;
    cudaSupport = config.foxDen.nvidia.enable;
    rocmSupport = config.foxDen.amdgpu.enable;
    packageOverrides =
      pkgs:
      let
        stdenvNoCheck = pkgs.stdenv // {
          mkDerivation =
            derivator:
            (pkgs.stdenv.mkDerivation (
              finalAttrs:
              (derivator finalAttrs)
              // {
                doCheck = false;
              }
            ));
        };
      in
      {
        # Redis/Valkey check break and also take ages
        redis = pkgs.redis.override {
          useSystemJemalloc = false;
          stdenv = stdenvNoCheck;
        };
        valkey = pkgs.valkey.override {
          useSystemJemalloc = false;
          stdenv = stdenvNoCheck;
        };
        onnxruntime =
          if config.foxDen.amdgpu.enable then
            onnxruntimeVitisAI (pkgs.onnxruntime.override {
              rocmSupport = false;
            }) nix-amd-npu.packages.${systemArch}.xrt
          else
            pkgs.onnxruntime;
        lua = pkgs.luajit;
      };
    permittedInsecurePackages = [
      "gradle-7.6.6" # TODO: What is pulling this in?
    ];
  };

  pkgs = import nixpkgs {
    system = systemArch;
    config = nixPkgConfig;
    overlays = [
      build-gradle-application.overlays.default
      nix-amd-npu.overlays.default
    ];
  };

  localPackages = lib.attrsets.genAttrs (lib.attrNames (builtins.readDir ../../packages)) (
    name: import ../../packages/${name}/package.nix (inputs // { inherit pkgs; })
  );
in
{
  imports = [
    nixpkgs.nixosModules.readOnlyPkgs
  ];

  config.nixpkgs.pkgs = lib.mergeAttrsList (
    [
      pkgs
      {
        config = nixPkgConfig;
      }
      localPackages
    ]
    ++ (map addPackage (lib.attrValues inputsWithoutInternal))
  );

  config.home-manager.useGlobalPkgs = true;
}
