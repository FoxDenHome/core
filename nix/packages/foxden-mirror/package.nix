{ pkgs, lib, ... }:
let
  packageJson = lib.trivial.importJSON ./package.json;
in
(pkgs.buildNpmPackage {
  name = packageJson.name;
  version = packageJson.version;
  src = ./.;
  npmDeps = pkgs.importNpmLock { npmRoot = ./.; };
  npmConfigHook = pkgs.importNpmLock.npmConfigHook;
})
