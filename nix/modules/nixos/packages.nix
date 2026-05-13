inputs@{
  nixpkgs,
  nixpkgs-unstable,
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
    "nixpkgs-unstable" = true;
    "impermanence" = true;
    "lanzaboote" = true;
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
    ];
  };

  pkgsConfig = {
    system = systemArch;
    config = nixPkgConfig;
    overlays = [
      build-gradle-application.overlays.default
      (final: prev: {
        python3 = prev.python3.override {
          packageOverrides = pfinal: pprev: {
            aiocache = pprev.aiocache.overridePythonAttrs (_: {
              doCheck = false; # TODO: Remove once https://github.com/NixOS/nixpkgs/issues/387010
            });
          };
        };
      })
    ];
  };

  mkPkgs = rawFlake: patches: let
    tempPkgs = import rawFlake {
      system = systemArch;
    };
    patchedFlake = tempPkgs.applyPatches {
      src = tempPkgs.path;
      patches = map (tempPkgs.fetchpatch2) patches;
    };
  in
    import patchedFlake pkgsConfig;

  pkgs = mkPkgs nixpkgs [
    {
      url = "https://patch-diff.githubusercontent.com/raw/NixOS/nixpkgs/pull/519944.patch";
      excludes = [
        "pkgs/os-specific/linux/zfs/unstable.nix"
      ];
      hash = "sha256-O8lsokyXwohgnkPxfrNX5MFX16lTachxFIEQ0nP955o=";
    }
  ];
  pkgsUnstable = mkPkgs nixpkgs-unstable [];

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
        inherit pkgsUnstable;
      }
      localPackages
    ]
    ++ (map addPackage (lib.attrValues inputsWithoutInternal))
  );

  config.home-manager.useGlobalPkgs = true;
}
