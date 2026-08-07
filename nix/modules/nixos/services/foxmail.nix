{
  pkgs,
  lib,
  config,
  foxDenLib,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.foxMail;
  svcHostName = services.getFirstFQDN config svcConfig;

  extendConfig =
    cfg:
    cfg
    // {
      sender = cfg.sender // {
        domain = if svcConfig.senderDomain == "" then svcHostName else svcConfig.senderDomain;
        dkim = cfg.sender.dkim // {
          selector = lib.head (lib.splitString "." svcHostName);
        };
      };
      receiver = cfg.receiver // {
        smtp = cfg.receiver.smtp // {
          domain = svcHostName;
        };
      };
    };

  # TODO: Gateway config might need global config in the future, but only icefox uses this
  #       and icefox only serves itself
  configFile =
    let
      configData = extendConfig (
        foxDenLib.global.foxmail.getForGateway config svcConfig.configFromGateway
      );
    in
    pkgs.writers.writeYAML "config.yml" configData;
in
{
  options.foxDen.services.foxMail = {
    configFromGateway = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    senderDomain = lib.mkOption {
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
