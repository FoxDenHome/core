{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.pinchflat;

  stateDir = "/var/lib/pinchflat";
in
{
  options.foxDen.services.pinchflat = {
    mediaDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory Pinchflat downloads videos into";
    };
  }
  // (services.http.mkOptions {
    name = "Pinchflat YouTube archiver";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "pinchflat";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-pinchflat";
        target = "proxy_pass http://127.0.0.1:8945;";
      }).config
      {
        sops.secrets.pinchflat = config.lib.foxDen.sops.mkIfAvailable { };

        services.pinchflat = {
          enable = true;
          # Pinchflat always listens on all interfaces, which would let other
          # hosts on the VLAN reach it without going through oauth2-proxy.
          package = pkgs.pinchflat.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace config/runtime.exs \
                --replace-fail "else: {0, 0, 0, 0}" "else: {127, 0, 0, 1}"
            '';
          });
          port = 8945;
          mediaDir = svcConfig.mediaDir;
          group = "share";
          secretsFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.pinchflat.path;
        };

        systemd.services.pinchflat = {
          serviceConfig = {
            BindPaths = [
              svcConfig.mediaDir
            ];
            # NAS files are group-writable for the share group
            UMask = "0002";
          };
        };

        environment.persistence."/nix/persist/pinchflat" = {
          hideMounts = true;
          directories = [
            {
              directory = stateDir;
              user = config.services.pinchflat.user;
              group = config.services.pinchflat.group;
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
