{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.wyoming;
in
{
  options.foxDen.services.wyoming = {
    language = lib.mkOption {
      type = lib.types.str;
      default = "en";
    };
    sttModel = lib.mkOption {
      type = lib.types.str;
      description = "Speech-to-text model (auto picks one based on language)";
      default = "auto";
    };
    ttsVoice = lib.mkOption {
      type = lib.types.str;
      default = "en_US-lessac-medium";
    };
    sttPort = lib.mkOption {
      type = lib.types.port;
      default = 10300;
    };
    ttsPort = lib.mkOption {
      type = lib.types.port;
      default = 10200;
    };
  }
  // services.mkOptions {
    name = "Wyoming speech-to-text and text-to-speech servers";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "wyoming-faster-whisper-default";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "wyoming-piper-default";
      }).config
      {
        services.wyoming.faster-whisper.servers.default = {
          enable = true;
          zeroconf.enable = false;
          uri = "tcp://0.0.0.0:${toString svcConfig.sttPort}";
          inherit (svcConfig) language;
          model = svcConfig.sttModel;
        };

        services.wyoming.piper.servers.default = {
          enable = true;
          zeroconf.enable = false;
          uri = "tcp://0.0.0.0:${toString svcConfig.ttsPort}";
          voice = svcConfig.ttsVoice;
        };
      }
    ]
  );
}
