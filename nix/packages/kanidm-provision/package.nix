{ lib, pkgs, ... }:
pkgs.rustPlatform.buildRustPackage (finalAttrs: {
  pname = "kanidm-provision";
  version = "1.3.0";

  # TODO: Go back upstream once upstream releases this
  src = pkgs.fetchFromGitHub {
    owner = "oddlama";
    repo = "kanidm-provision";
    rev = "304a048bf6ed1a01678db243807a5619a0e32f61";
    hash = "sha256-k+m73Ih+LzBsanbplHIivoF7z+RcRvj6IeoesDdfImc=";
  };

  cargoHash = "sha256-dPTrIc/hTbMlFDXYMk/dTjqaNECazldfW43egDOwyLM=";

  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  passthru = {
    updateScript = pkgs.nix-update-script { };
  };

  meta = {
    description = "Small utility to help with kanidm provisioning";
    homepage = "https://github.com/oddlama/kanidm-provision";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "kanidm-provision";
  };
})
