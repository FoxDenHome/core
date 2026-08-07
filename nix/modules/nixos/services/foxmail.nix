{
  pkgs,
  lib,
  config,
  nixosConfigurations,
  foxDenLib,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.foxMail;
  hostName = services.getFirstFQDN config svcConfig;

  extendConfig =
    cfg:
    cfg
    // {
      sender = cfg.sender // {
        domain = hostName;
        dkim = cfg.sender.dkim // {
          selector = lib.head (lib.splitString "." hostName);
        };
      };
      receiver = cfg.receiver // {
        smtp = cfg.receiver.smtp // {
          domain = hostName;
        };
      };
    };

  configData =
    if svcConfig.configFromGateway != "" then
      extendConfig (foxDenLib.global.foxmail.getForGateway nixosConfigurations svcConfig.configFromGateway)
    else
      foxDenLib.global.foxmail.boilerplateCfg // svcConfig.config;

  configFile =
    if svcConfig.configText != "" then
      pkgs.writers.writeText "config.yml" svcConfig.configText
    else
      pkgs.writers.writeYAML "config.yml" configData;
in
{
  options.foxDen.services.foxMail = {
    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.any;
    };
    configText = lib.mkOption {
      type = lib.types.str;
      description = "Raw text configuration for foxMail, alternative to 'config' option.";
      default = "";
    };
    configFromGateway = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
  }
  // services.mkOptions {
    name = "foxMail";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "foxMail";
      }).config
      {
        systemd.services.foxMail = {
          serviceConfig = {
            DynamicUser = true;
            Type = "simple";
            BindReadOnlyPaths = [ configFile ];
            StateDirectory = "foxmail";
            Environment = [
              "DATA_DIR=/var/lib/foxmail"
              "CONFIG_FILE=${configFile}"
            ];
            ExecStart = [ "${pkgs.foxMail}/bin/foxMail" ];
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
