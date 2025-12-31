{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  hostName = services.getFirstFQDN config svcConfig;

  mkDir = (
    dir: {
      directory = dir;
      user = "ntfy";
      group = "ntfy";
      mode = "u=rwx,g=,o=";
    }
  );

  configYaml = {
    base-url = "https://${hostName}";
    behind-proxy = true;
    auth-file = "/var/lib/ntfy/user.db";
    auth-default-access = "deny-all";
    enable-signup = false;
  };

  svcConfig = config.foxDen.services.ntfy;
in
{
  options.foxDen.services.ntfy = (
    services.http.mkOptions {
      svcName = "ntfy";
      name = "Ntfy service";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "ntfy";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-ntfy";
        target = "proxy_pass http://127.0.0.1:8082;";
      }).config
      {
        systemd.services.ntfy = {
          serviceConfig = {
            ExecStart = "${pkgs.ntfy}/bin/ntfy serve --config /etc/ntfy/server.yml";
            Type = "simple";
            BindReadOnlyPaths = [
              "${pkgs.writers.writeYAML "server.yml" configYaml}:/etc/ntfy/server.yml"
            ];
            StateDirectory = "ntfy";
            CacheDirectory = "ntfy";
          };

          wantedBy = [ "multi-user.target" ];
        };

        environment.persistence."/nix/persist/ntfy" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/ntfy")
          ];
        };
      }
    ]
  );
}
