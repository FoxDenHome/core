{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.anisette;

  dataDir = "/var/lib/anisette";
  cmdline = "${pkgs.anisette-v3-server}/bin/anisette-v3-server --host 127.0.0.1 --adi-path ${dataDir}";
in
{
  options.foxDen.services.anisette = services.http.mkOptions {
    name = "Anisette";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-anisette";
        target = "proxy_pass http://127.0.0.1:6969;";
      }).config
      (services.make {
        inherit svcConfig pkgs config;
        name = "anisette";
      }).config
      {
        systemd.services.anisette = {
          serviceConfig = {
            ExecStartPre = [ "${cmdline} --skip-server-startup" ];
            ExecStart = [ cmdline ];

            DynamicUser = true;
            Type = "simple";

            Environment = [ "RUNTIME_DIRECTORY=/run/anisette" ];
            WorkingDirectory = dataDir;
            StateDirectory = "anisette";
            RuntimeDirectory = "anisette";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
