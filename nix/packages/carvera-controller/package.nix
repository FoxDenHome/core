{
  pkgs,
  nixpkgs,
  lib,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
  ...
}:
let
  pypkgs-build-requirements = {
    altgraph = [ "setuptools" ];
    buildozer = [ "setuptools" ];
    carvera-controller-community = [ "hatchling" ];
    certifi = [ "setuptools" ];
    charset-normalizer = [ "setuptools" ];
    distlib = [ "setuptools" ];
    docutils = [ "flit-core" ];
    filelock = [
      "hatchling"
      "hatch-vcs"
    ];
    filetype = [ "setuptools" ];
    hid = [ "setuptools" ];
    idna = [ "flit-core" ];
    markupsafe = [ "setuptools" ];
    packaging = [ "flit-core" ];
    platformdirs = [
      "hatchling"
      "hatch-vcs"
    ];
    pygments = [ "hatchling" ];
    pyquicklz = [
      "setuptools"
      "cython"
    ];
    pyserial = [ "setuptools" ];
    pyyaml = [ "setuptools" ];
    ruamel-yaml = [ "setuptools" ];
    ruamel-yaml-clib = [ "setuptools" ];
    toml = [ "setuptools" ];
    ptyprocess = [ "flit-core" ];
    jinja2 = [ "flit-core" ];
    pexpect = [ "setuptools" ];
    pyinstaller = [
      "hatchling"
      pkgs.zlib
    ];
    pyinstaller-versionfile = [ "poetry-core" ];
    sh = [ "poetry-core" ];
    typing-extensions = [ "flit-core" ];
    urllib3 = [
      "hatchling"
      "hatch-vcs"
    ];
    virtualenv = [
      "hatchling"
      "hatch-vcs"
    ];
    requests = [ "setuptools" ];
    kivy = [
      "setuptools"
      "cython"
      pkgs.libGL
    ];
  };

  inherit (pkgs.callPackages pyproject-nix.build.util { }) mkApplication;

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  version = "2.0.0";

  patchedSrc = pkgs.stdenvNoCC.mkDerivation {
    name = "carvera-controller-community-patched";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "Carvera-Community";
      repo = "Carvera_Controller";
      rev = "v${version}";
      sha256 = "sha256-bd+XxEI5d7pgO4z4s3WU1SWl1FbHvEHXPyGt82VkVUk=";
    };

    unpackPhase = "true";

    installPhase = ''
      cp -r $src $out
      chmod 755 $out $out/carveracontroller
      rm -f $out/poetry.lock $out/pyproject.toml $out/uv.lock $out/carveracontroller/__version__.py
      echo '__version__ = "${version}"' > $out/carveracontroller/__version__.py
      cp ${./pyproject.toml} $out/pyproject.toml
      cp ${./uv.lock} $out/uv.lock
    '';
  };

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = patchedSrc; };
  python = pkgs.python312;
  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {
      inherit python;
    }).overrideScope
      (
        nixpkgs.lib.composeManyExtensions [
          pyproject-build-systems.overlays.default
          overlay
          (
            final: prev:
            builtins.mapAttrs (
              package: build-requirements:
              (builtins.getAttr package prev).overrideAttrs (old: {
                nativeBuildInputs =
                  (old.nativeBuildInputs or [ ])
                  ++ (builtins.map (
                    pkg: if builtins.isString pkg then builtins.getAttr pkg prev else pkg
                  ) build-requirements);
              })
            ) pypkgs-build-requirements
          )
        ]
      );
in
mkApplication {
  venv = pythonSet.mkVirtualEnv "carvera-controller-community" workspace.deps.default;
  package = pythonSet.carvera-controller-community;
}
