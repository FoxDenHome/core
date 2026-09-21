{ nixpkgs, ... }:
{
  driverConfigType = with nixpkgs.lib.types; submodule { options = { }; };
  build =
    { ... }:
    {
      config.systemd = { };
    };
  rootDevices = _: [ ];

  hooks =
    { ... }:
    {
      start = [ ];
      stop = [ ];
    };
}
