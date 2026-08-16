{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.foxDen.lsi.enable = lib.mkEnableOption "Enable LSI SAS HBA support";

  config = lib.mkIf config.foxDen.lsi.enable {
    environment.systemPackages = with pkgs; [
      storcli
    ];
  };
}
