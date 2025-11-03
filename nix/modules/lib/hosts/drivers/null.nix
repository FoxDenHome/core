{ nixpkgs, ... }:
{
  driverConfigType = with nixpkgs.lib.types; submodule { options = {}; };
  build = { ... }: { config.systemd = {}; };
  hooks = { ... }: { start = [ ]; stop = [ ]; };
}
