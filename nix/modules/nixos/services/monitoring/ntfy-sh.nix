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
        sops.secrets.ntfy-sh = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "ntfy-sh";
          group = "ntfy-sh";
        };

        services.ntfy-sh = {
          enable = true;
          environmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.ntfy-sh.path;
          settings = {
            base-url = "https://${hostName}";
            listen-http = "127.0.0.1:2586";
            behind-proxy = true;
            auth-default-access = "deny-all";
            enable-signup = false;
            auth-access = [
              "islandfox:alerts:wo"
              "bengalfox:alerts:wo"
              "icefox:alerts:wo"
              "*:general-ro:ro"
              "*:general-wo:wo"
              "*:general-rw:rw"
            ];
          };
        };
      }
    ]
  );
}
