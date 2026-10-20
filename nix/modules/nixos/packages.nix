inputs@{
  nixpkgs,
  config,
  lib,
  systemArch,
  flakeInputs,
  build-gradle-application,
  ...
}:
let
  internalPackages = {
    "nixpkgs" = true;
    "impermanence" = true;
    "sops-nix" = true;
    "self" = true;
  };

  inputsWithoutInternal = lib.filterAttrs (
    name: value:
    let
      valType = if lib.isAttrs value then (value._type or null) else null;
    in
    valType == "flake" && !(internalPackages.${name} or false)
  ) flakeInputs;

  removeDefaultPackage = lib.filterAttrs (name: value: name != "default");
  addPackage = (
    mod:
    if (mod.packages or null) != null && (mod.packages.${systemArch} or null) != null then
      removeDefaultPackage mod.packages.${systemArch}
    else
      { }
  );

  nixPkgConfig = {
    allowUnfree = true;
    cudaSupport = config.foxDen.nvidia.enable;
    rocmSupport = config.foxDen.amdgpu.enable;
  };

  pkgsConfig = {
    system = systemArch;
    config = nixPkgConfig;
    overlays = [
      build-gradle-application.overlays.default
      (
        final: prev:
        lib.optionalAttrs nixPkgConfig.cudaSupport {
          # patchelf 0.19 aborts (splitIndex assertion in shiftFile) when this hook rewrites the
          # RUNPATH of non-PIE executables autoPatchelf already patched (libcufile's gdscheck,
          # tensorrt's trtexec, ...). autoPatchelf's pass already leaves those segfaulting, so
          # skip them and keep patching the shared libraries, which are what actually gets used.
          autoAddDriverRunpath = prev.autoAddDriverRunpath.override {
            addDriverRunpath = prev.addDriverRunpath.overrideAttrs (old: {
              buildCommand = old.buildCommand + ''
                substituteInPlace $out/nix-support/setup-hook \
                  --replace-fail 'if ! isELF "$file"; then continue; fi' \
                    'if ! isELF "$file"; then continue; fi
                if [ "$(od -An -tx1 -j16 -N1 "$file")" = " 02" ]; then continue; fi'
              '';
            });
          };
        }
      )
      (final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            # Only the TypeError wording differs ("Expected str, got int" vs "must be str")
            pyopenjtalk-plus = pyPrev.pyopenjtalk-plus.overridePythonAttrs (old: {
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_run_njd_from_mecab_invalid_input_should_not_break_next_call"
              ];
            });
          })
        ];
      })
      (
        final: prev:
        lib.optionalAttrs nixPkgConfig.rocmSupport {
          pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
            (pyFinal: pyPrev: {
              # The python wheel only ships providers_shared, so the MIGraphX EP silently falls back to CPU
              onnxruntime = pyPrev.onnxruntime.overridePythonAttrs (old: {
                postInstall = (old.postInstall or "") + ''
                  ln -s ${final.onnxruntime}/lib/libonnxruntime_providers_migraphx.so \
                    $out/${pyFinal.python.sitePackages}/onnxruntime/capi/
                '';
              });
              # OpenCV dnn and MIGraphX both register tensor_shape.proto in the shared libprotobuf,
              # which aborts the process when both are loaded (e.g. immich-machine-learning)
              opencv4 = pyPrev.opencv4.overrideAttrs (old: {
                buildInputs = lib.remove final.protobuf old.buildInputs;
                cmakeFlags =
                  lib.subtractLists [
                    (lib.cmakeBool "BUILD_PROTOBUF" false)
                    (lib.cmakeBool "PROTOBUF_UPDATE_FILES" true)
                  ] old.cmakeFlags
                  ++ [
                    (lib.cmakeBool "BUILD_PROTOBUF" true)
                    (lib.cmakeBool "PROTOBUF_UPDATE_FILES" false)
                  ];
              });
            })
          ];
        }
      )
    ];
  };

  # fetchpatch2 preprocessor adding an easy alias to just load nixpkgs PRs by ID
  fetchpatch2PreProc =
    patch:
    if lib.attrsets.hasAttr "pr" patch then
      (
        {
          url = "https://patch-diff.githubusercontent.com/raw/NixOS/nixpkgs/pull/${toString patch.pr}.patch";
        }
        // (lib.filterAttrs (name: value: name != "pr") patch)
      )
    else
      patch;

  mkPkgs =
    rawFlake: patches:
    let
      tempPkgs = import rawFlake {
        system = systemArch;
      };
      mkPatchFile =
        patch: if builtins.isPath patch then patch else tempPkgs.fetchpatch2 (fetchpatch2PreProc patch);
      processedFlake =
        if patches == [ ] then
          rawFlake
        else
          tempPkgs.applyPatches {
            src = tempPkgs.path;
            patches = map mkPatchFile patches;
          };
    in
    import processedFlake pkgsConfig;

  pkgs = mkPkgs nixpkgs [ ];

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
