{
  pkgs,
  lib,
  config,
  foxDenLib,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.foxIngress;

  # TODO: Gateway config might need global config in the future, but only icefox uses this
  #       and icefox only serves itself
  configData =
    if svcConfig.configFromGateway != "" then
      foxDenLib.global.foxingress.getForGateway config svcConfig.configFromGateway
    else
      foxDenLib.global.foxingress.boilerplateCfg // svcConfig.config;

  configFile =
    if svcConfig.configText != "" then
      pkgs.writers.writeText "config.yml" svcConfig.configText
    else
      pkgs.writers.writeYAML "config.yml" configData;
in
{
  options.foxDen.services.foxIngress = {
    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.any;
    };
    configText = lib.mkOption {
      type = lib.types.str;
      description = "Raw text configuration for foxIngress, alternative to 'config' option.";
      default = "";
    };
    configFromGateway = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
  }
  // services.mkOptions {
    name = "foxIngress";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "foxingress";
      }).config
      {
        systemd.services.foxingress = {
          serviceConfig = {
            DynamicUser = true;
            Type = "simple";
            BindReadOnlyPaths = [ configFile ];
            Environment = [
              "CONFIG_FILE=${configFile}"
            ];
            ExecStart = [ "${pkgs.foxingress}/bin/foxIngress" ];
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
