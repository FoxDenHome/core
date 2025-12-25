{ pkgs, poetry2nix, ... }:
let
  inherit (poetry2nix.lib.mkPoetry2Nix { inherit pkgs; }) mkPoetryApplication;

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

      pkgs.SDL2
      pkgs.SDL2_image
      pkgs.SDL2_ttf
      pkgs.SDL2_mixer

      pkgs.mesa
      pkgs.gst_all_1.gstreamer
    ];
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
        configurePhase =
          if package == "kivy" then
            ''
              export KIVY_NO_CONFIG=1
            ''
          else
            "";
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
