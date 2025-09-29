{ foxDenLib, pkgs, lib, config, ... }:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.kiwix;

  defaultDataDir = "/var/lib/kiwix";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);
in
{
  options.foxDen.services.kiwix = {
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = defaultDataDir;
      description = "Directory to store kiwix data";
    };
  } // (services.http.mkOptions { svcName = "kiwix"; name = "Kiwix server"; });

  config = lib.mkIf svcConfig.enable (lib.mkMerge [
    (services.make {
      name = "kiwix";
      inherit svcConfig pkgs config;
    }).config
    (services.http.make {
      inherit svcConfig pkgs config;
      name = "caddy-kiwix";
      target = "reverse_proxy http://127.0.0.1:8080";
    }).config
    {
      environment.systemPackages = [
        pkgs.kiwix-tools
      ];

      users.users.kiwix = {
        isSystemUser = true;
        description = "kiwix service user";
        group = "kiwix";
      };
      users.groups.kiwix = {};

      systemd.services.kiwix = {
        serviceConfig = {
          BindPaths = [
            svcConfig.dataDir
          ];

          User = "kiwix";
          Group = "kiwix";

          ExecStart = [ "${pkgs.kiwix-tools}/bin/kiwix-serve --port=8080 *.zim" ];

          StateDirectory = ifDefaultData "kiwix";
        };

        wantedBy = [ "multi-user.target" ];
      };

      environment.persistence."/nix/persist/kiwix" = ifDefaultData {
        hideMounts = true;
        directories = [
          { directory = defaultDataDir; user = "kiwix"; group = "kiwix"; mode = "u=rwx,g=,o="; }
        ];
      };
    }
  ]);
}
