{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.spaceage-tts;
in
{
  options.foxDen.services.spaceage-tts = (
    services.http.mkOptions {
      svcName = "spaceage-tts";
      name = "SpaceAge TTS";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "spaceage-tts";
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-spaceage-tts";
        target = "proxy_pass http://127.0.0.1:8000;";
      }).config
      {
        systemd.services.spaceage-tts = {
          serviceConfig = {
            DynamicUser = true;
            Type = "simple";
            ExecStart = "${pkgs.spaceage-tts}/bin/TTS";
            Environment = [
              "OUT_DIR=/var/lib/spaceage-tts"
              "LISTEN_ADDR=127.0.0.1:8000"
            ];
            StateDirectory = "spaceage-tts";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
