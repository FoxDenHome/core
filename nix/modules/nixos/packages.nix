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
      fetchpatch2PR = patch: tempPkgs.fetchpatch2 (fetchpatch2PreProc patch);
      processedFlake =
        if patches == [ ] then
          rawFlake
        else
          tempPkgs.applyPatches {
            src = tempPkgs.path;
            patches = map fetchpatch2PR patches;
          };
    in
    import processedFlake pkgsConfig;

  pkgs = mkPkgs nixpkgs [
    {
      # ZFS 2.4.2
      pr = 519944;
      excludes = [
        "pkgs/os-specific/linux/zfs/unstable.nix"
      ];
      hash = "sha256-O8lsokyXwohgnkPxfrNX5MFX16lTachxFIEQ0nP955o=";
    }
    {
      # Kanidm 1.10.2
      pr = 520046;
      hash = "sha256-RinqEkcEeYmJQ2/yw9vWAAbEo/HJ/FJaK4cPFmk3j3M=";
    }
  ];
  pkgsUnstable = mkPkgs nixpkgs-unstable [ ];

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
