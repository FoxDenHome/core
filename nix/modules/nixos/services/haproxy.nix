{
  pkgs,
  lib,
  config,
  foxDenLib,
  haproxy,
  ...
}:
let
  svcConfig = config.foxDen.services.haproxy;
in
{
  options.foxDen.services.haproxy = {
    config = lib.mkOption {
      type = lib.types.str;
      description = "Raw text configuration for HAProxy";
      default = "";
    };
    configFromGateway = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
  }
  // foxDenLib.services.mkOptions {
    svcName = "haproxy";
    name = "HAProxy";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (foxDenLib.services.make {
        inherit pkgs config svcConfig;
        name = "haproxy";
      }).config
      {
        services.haproxy.enable = true;
        services.haproxy.config =
          if svcConfig.configFromGateway != "" then
            haproxy.${svcConfig.configFromGateway}
          else
            svcConfig.config;

        systemd.services.haproxy = {
          serviceConfig = {
            BindReadOnlyPaths = (
              foxDenLib.services.mkEtcPaths [
                "haproxy.cfg"
              ]
            );
          };
        };
      }
    ]
  );
}
