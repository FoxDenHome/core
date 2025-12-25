{ pkgs, poetry2nix, ... }:
let
  inherit (poetry2nix.lib.mkPoetry2Nix { inherit pkgs; }) mkPoetryApplication;

  pypkgs-build-requirements = {
    altgraph = [ "setuptools" ];
    carvera-controller-community = [ "hatchling" ];
    certifi = [ "setuptools" ];
    charset-normalizer = [ "setuptools" ];
    distlib = [ "setuptools" ];
    docutils = [ "flit-core" ];
    filelock = [ "hatchling" ];
    filetype = [ "setuptools" ];
    hid = [ "setuptools" ];
    idna = [ "flit-core" ];
    markupsafe = [ "setuptools" ];
    packaging = [ "flit-core" ];
    platformdirs = [ "hatchling" ];
    pygments = [ "hatchling" ];
    pyquicklz = [ "setuptools" ];
    pyserial = [ "setuptools" ];
    pyyaml = [ "setuptools" ];
    ruamel-yaml = [ "setuptools" ];
    ruamel-yaml-clib = [ "setuptools" ];
    toml = [ "setuptools" ];
  };
in
mkPoetryApplication {
  projectDir = pkgs.fetchFromGitHub {
    owner = "Carvera-Community";
    repo = "Carvera_Controller";
    rev = "v2.0.0";
    sha256 = "sha256-bd+XxEI5d7pgO4z4s3WU1SWl1FbHvEHXPyGt82VkVUk=";
  };
  python = pkgs.python312;
  overrides = (
    final: prev:
    builtins.mapAttrs (
      package: build-requirements:
      (builtins.getAttr package prev).overridePythonAttrs (old: {
        buildInputs =
          (old.buildInputs or [ ])
          ++ (builtins.map (
            pkg: if builtins.isString pkg then builtins.getAttr pkg prev else pkg
          ) build-requirements);
      })
    ) pypkgs-build-requirements
  );
  # https://github.com/Carvera-Community/Carvera_Controller.git v2.0.0
}
