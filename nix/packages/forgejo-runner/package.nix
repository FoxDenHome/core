{
  pkgs,
  nixpkgs-unstable,
  systemArch,
  ...
}:
let
  version = "12.0.1";
in
nixpkgs-unstable.legacyPackages.${systemArch}.forgejo-runner.override {
  buildGoModule =
    inputs:
    pkgs.buildGoModule (
      inputs
      // {
        inherit version;
        vendorHash = "sha256-ReGxoPvW4G6DbFfR2OeeT3tupZkpLpX80zK824oeyVg=";
        doCheck = false;

        ldflags = [
          "-s"
          "-w"
          "-X code.forgejo.org/forgejo/runner/v12/internal/pkg/ver.version=v${version}"
        ];
      }
    );
  fetchFromGitea =
    inputs:
    pkgs.fetchFromGitea (
      inputs
      // {
        rev = "v${version}";
        hash = "sha256-hxMhHsMxmfTzkb+iZRx+4nS5MM6hGd7py8KozgUd9aA=";
      }
    );
}
