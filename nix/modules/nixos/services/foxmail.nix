{
  pkgs,
  lib,
  config,
  foxDenLib,
  ...
}: # sender.domain, reciever.smtp.domain, sender.dkim.selector
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
      receiver = cfg.reciever // {
        smtp = cfg.receiver.smtp // {
          domain = hostName;
        };
      };
    };

  # TODO: Gateway config might need global config in the future, but only icefox uses this
  #       and icefox only serves itself
  configData =
    if svcConfig.configFromGateway != "" then
      extendConfig (foxDenLib.global.foxMail.getForGateway config svcConfig.configFromGateway)
    else
      foxDenLib.global.foxMail.boilerplateCfg // svcConfig.config;

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
