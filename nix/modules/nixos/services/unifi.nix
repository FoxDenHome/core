{
  foxDenLib,
  pkgs,
  lib,
  config,
  nixpkgs-unstable,
  systemArch,
  ...
}:
let
  services = foxDenLib.services;

  mkDir = (
    dir: {
      directory = dir;
      user = "unifi";
      group = "unifi";
      mode = "u=rwx,g=,o=";
    }
  );

  svcConfig = config.foxDen.services.unifi;

  nixpkgsUnstable = (
    import nixpkgs-unstable {
      system = systemArch;
      config = {
        allowUnfree = true;
      };
    }
  );
in
{
  options.foxDen.services.unifi = {
    enableHttp = lib.mkEnableOption "HTTP reverse proxy for UniFi Web UI";
  }
  // (services.http.mkOptions {
    svcName = "unifi";
    name = "UniFi Network Controller";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "unifi";
        inherit svcConfig pkgs config;
      }).config
      (lib.mkIf svcConfig.enableHttp
        (services.http.make {
          inherit svcConfig pkgs config;
          name = "http-unifi";
          target = ''
            proxy_pass https://127.0.0.1:8443;
            proxy_ssl_verify off;
          '';
        }).config
      )
      {
        services.unifi = {
          enable = true;
          unifiPackage = nixpkgsUnstable.unifi; # TODO: pkgs. once 25.11
        };

        systemd.services.unifi = {
          confinement.packages = [
            config.services.unifi.unifiPackage
            config.services.unifi.mongodbPackage
            config.services.unifi.jrePackage
          ];
          serviceConfig = {
            StateDirectory = "unifi";
          };
        };

        environment.persistence."/nix/persist/unifi" = {
          hideMounts = true;
          directories = [
            (mkDir "/var/lib/unifi")
          ];
        };
      }
    ]
  );
}
