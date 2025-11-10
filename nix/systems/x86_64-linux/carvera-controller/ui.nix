{ pkgs, ... } :
{
  environment.systemPackages = with pkgs; [
    carvera-controller
  ];
}
