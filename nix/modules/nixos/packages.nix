inputs@{
  nixpkgs,
  config,
  lib,
  systemArch,
  flakeInputs,
  build-gradle-application,
  nixpkgs-podman,
  ...
}:
let
  internalPackages = {
    "nixpkgs" = true;
    "nixpkgs-podman" = true;
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
    permittedInsecurePackages = [
      "gradle-7.6.6" # TODO: What is pulling this in?
      "immich-2.7.5"
      "openssl-3.0.22"
    ];
    problems.handlers = {
      zfs.broken = "warn"; # TODO: Remove this once ZFS officially supports 7.1
    };
  };

  pkgsConfig = {
    system = systemArch;
    config = nixPkgConfig;
    overlays = [
      build-gradle-application.overlays.default
      # TODO: drop once https://github.com/podman-container-tools/podman/issues/29805 is fixed
      (final: prev: {
        podman = nixpkgs-podman.legacyPackages.${systemArch}.podman;
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
