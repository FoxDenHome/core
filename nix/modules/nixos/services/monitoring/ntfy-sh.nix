{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;
  svcConfig = config.foxDen.services.ntfy-sh;
  hostName = services.getFirstFQDN config svcConfig;

  mkDir = (
    dir: {
      directory = dir;
      user = config.services.ntfy-sh.user;
      group = config.services.ntfy-sh.group;
      mode = "u=rwx,g=,o=";
    }
  );
in
{
  options.foxDen.services.ntfy-sh = (
    services.http.mkOptions {
      svcName = "ntfy-sh";
      name = "Ntfy service";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "ntfy-sh";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-ntfy-sh";
        target = "proxy_pass http://127.0.0.1:2586;";
      }).config
      {
        services.ntfy-sh.enable = true;
        services.ntfy-sh.settings = {
          base-url = "https://${hostName}";
          listen-http = "127.0.0.1:2586";
          behind-proxy = true;
          auth-default-access = "deny-all";
          enable-signup = false;
        };
      }
    ]
  );
}
