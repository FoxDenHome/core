{ config, lib, ... } :
{
  options.foxDen.deploy.push = lib.mkEnableOption "Enable push updates";
  config = lib.mkIf config.foxDen.deploy.push {
    
  };
}
