inputs@{
  nixpkgs,
  config,
  lib,
  systemArch,
  flakeInputs,
  build-gradle-application,
  nix-amd-npu,
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
