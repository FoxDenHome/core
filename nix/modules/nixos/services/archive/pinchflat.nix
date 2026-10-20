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

  potPort = 4416;

  # yt-dlp with the bgutil PO token provider plugin, served by pinchflat-pot in
  # the same netns. Pinchflat-NGX passes the base_url from POT_PROVIDER_URL, but
  # only loads the plugin itself from its Docker image's /opt path.
  ytDlpWithPot = pkgs.yt-dlp.overridePythonAttrs (old: {
    dependencies = (old.dependencies or [ ]) ++ [ pkgs.bgutil-ytdlp-pot-provider.plugin ];
  });

  # Age-restricted videos are SABR-only on the default authenticated clients, but
  # mweb (with a PO token) still gets plain https formats. This has to apply to every
  # yt-dlp call: pinchflat only passes its yt-dlp-configs to the download itself, not
  # to the downloadability precheck that runs before it. NGX's per-source player
  # client setting does cover every call, but adds nothing for sources left on
  # "Default"; a source that sets one overrides this.
  ytDlp = pkgs.symlinkJoin {
    name = "yt-dlp-pinchflat";
    paths = [ ytDlpWithPot ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/yt-dlp \
        --add-flags "--extractor-args youtube:player_client=default,mweb,web_safari"
    '';
  };
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
      (services.make {
        name = "pinchflat-pot";
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
          package = (pkgs.pinchflat-ngx.override { yt-dlp = ytDlp; }).overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace config/runtime.exs \
                --replace-fail "else: {0, 0, 0, 0}" "else: {127, 0, 0, 1}"
            '';
          });
          port = 8945;
          mediaDir = svcConfig.mediaDir;
          group = "share";
          secretsFile = config.lib.foxDen.sops.mkIfAvailable config.sops.secrets.pinchflat.path;
          extraConfig.POT_PROVIDER_URL = "http://127.0.0.1:${toString potPort}";
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

        # Proof-of-origin token server for YouTube (works around SABR-only formats)
        systemd.services.pinchflat-pot = {
          serviceConfig = {
            DynamicUser = true;
            Type = "simple";
            ExecStart = [
              "${pkgs.bgutil-ytdlp-pot-provider}/bin/bgutil-pot-server --host 127.0.0.1 --port ${toString potPort}"
            ];
          };
          wantedBy = [ "multi-user.target" ];
        };

        systemd.services.pinchflat = {
          wants = [ "pinchflat-pot.service" ];
          after = [ "pinchflat-pot.service" ];
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
