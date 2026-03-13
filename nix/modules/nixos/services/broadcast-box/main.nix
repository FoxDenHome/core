{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.broadcast-box;
  proxyTargetBase = "proxy_pass http://127.0.0.1:${builtins.toString config.services.broadcast-box.web.port}";
in
{
  options.foxDen.services.broadcast-box = (
    services.http.mkOptions {
      svcName = "broadcast-box";
      name = "Broadcast Box";
    }
  );

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "broadcast-box";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        name = "http-broadcast-box";
        inherit svcConfig pkgs config;
        target = "${proxyTargetBase};";
        extraHttpConfig =
          { ... }:
          ''
            js_import sdpfixer from sdpfixer.js;
          '';
        extraConfig =
          { proxyConfig, ... }:
          ''
            location = /api/raw_whip {
              ${proxyConfig}
              ${proxyTargetBase}/api/whip;
            }
            location = /api/raw_whep {
              ${proxyConfig}
              ${proxyTargetBase}/api/whep;
            }
            location = /api/whip {
              js_content sdpfixer.whip;
            }
            location = /api/whep {
              js_content sdpfixer.whep;
            }
          '';
      }).config
      {
        sops.secrets.broadcast-box = config.lib.foxDen.sops.mkIfAvailable { };
        services.broadcast-box = {
          enable = true;
          settings = {
            STREAM_PROFILE_POLICY = "RESERVED";
            INCLUDE_PUBLIC_IP_IN_NAT_1_TO_1_IP = true;
            NAT_ICE_CANDIDATE_TYPE = "srflx";
            STREAM_PROFILE_PATH = "/var/lib/broadcast-box/stream-profiles";
            LOGGING_DIRECTORY = "/var/lib/broadcast-box/logs";
            UDP_MUX_PORT = 3333;
            TCP_MUX_ADDRESS = ":3333";
            STUN_SERVERS = "stun.l.google.com:19302";
          };
        };
        systemd.services = {
          broadcast-box = {
            serviceConfig = {
              EnvironmentFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.broadcast-box.path;
              StateDirectory = "broadcast-box";
              DynamicUser = true; # already set upstream, but we MUST fail if that changes, because only /var/lib/private is in impermanence by default!
              ExecStartPre = [
                "${pkgs.coreutils}/bin/mkdir -p /var/lib/broadcast-box/stream-profiles /var/lib/broadcast-box/logs"
              ];
            };
          };
          http-broadcast-box = {
            serviceConfig = {
              BindReadOnlyPaths = [
                "${./sdpfixer.js}:/njs/lib/sdpfixer.js"
              ];
            };
          };
        };
      }
    ]
  );
}
