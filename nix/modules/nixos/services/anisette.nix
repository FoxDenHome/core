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
  cmdline = "${pkgs.anisette-v3-server}/bin/anisette-v3-server --host 127.0.0.1 --adi-path /var/lib/anisette";
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
            DynamicUser = true;
            Type = "simple";
            ExecStartPre = [ "${cmdline} --skip-server-startup" ];
            ExecStart = [ cmdline ];
            WorkingDirectory = "/var/lib/anisette";
            StateDirectory = "anisette";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
