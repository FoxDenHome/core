{
  nixpkgs,
  lib,
  systemArch,
  flakeInputs,
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
    mod: if (mod.packages or null) != null then removeDefaultPackage mod.packages.${systemArch} else { }
  );

  nixPkgConfig = {
    allowUnfree = true;
    packageOverrides = pkgs: {
      onnxruntime = pkgs.onnxruntime.override { cudaSupport = true; };
    };
    permittedInsecurePackages = [
      "gradle-7.6.6" # TODO: What is pulling this in?
    ];
  };

  pkgs = (
    import nixpkgs {
      system = systemArch;
      config = nixPkgConfig;
    }
  );

  localPackages = lib.attrsets.genAttrs (lib.attrNames (builtins.readDir ../../packages)) (
    name: import ../../packages/${name}/package.nix { inherit pkgs lib nixpkgs; }
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
}
