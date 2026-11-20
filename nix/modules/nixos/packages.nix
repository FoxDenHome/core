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
      (final: prev: {
        # 0.15.0 emits SCSI verify/endurance metrics it never registers in
        # Describe(), so every scrape fails with a 500 once a SAS drive reports them
        prometheus-smartctl-exporter = prev.prometheus-smartctl-exporter.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./services/monitoring/prometheus/smartctl-exporter-describe.patch
          ];
        });
        # cargo-setup-hook now forces system libs for every Rust build (AWS_LC_SYS_USE_SYSTEM,
        # a sentinel JEMALLOC_OVERRIDE, ...), which breaks tuwunel's aws-lc-sys and its
        # jevmalloc fork. Build them vendored, as before.
        matrix-tuwunel = prev.matrix-tuwunel.overrideAttrs {
          dontCargoUseSystemLibs = true;
        };
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
          # TODO: Remove once nixpkgs ce71e9daad ("rocmPackages.aotriton: fix build with Triton 3.9")
          # reaches nixos-unstable; 0.12b fails to compile its flash kernels with Triton 3.9
          rocmPackages = prev.rocmPackages.overrideScope (
            rFinal: rPrev: {
              aotriton = rPrev.aotriton.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [
                  (final.fetchpatch2 {
                    name = "triton-3.9-composed-tensors.patch";
                    url = "https://github.com/ROCm/aotriton/commit/ab24ced82e999dfaf05dfee46f6da50ca2c0561f.patch?full_index=1";
                    hash = "sha256-t4wwbEuuM0RPpyIvY3QaQAXHkCbSXA41tx0SxVgjn9o=";
                    postFetch = ''
                      substituteInPlace $out \
                        --replace-fail 'modules/flash/kernel/composed_tensors.py' 'tritonsrc/composed_tensors.py'
                    '';
                  })
                ];
              });
            }
          );
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
