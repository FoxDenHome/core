{
  config,
  pkgs,
  lib,
  ...
}:
let
  allPackages = config.services.cockpit.plugins ++ [ config.services.cockpit.package ];
in
{
  # BELOW FROM NIXPKGS UNSTABLE
  options.services.cockpit.plugins = lib.mkOption {
    type = with lib.types; listOf path;
    default = [ ];
    description = "Cockpit plugins to enable.";
  };
  # ABOVE FROM NIXPKGS UNSTABLE

  config = {
    services.cockpit = {
      enable = true;
      openFirewall = true;
      package = pkgs.pkgsUnstable.cockpit;
      allowed-origins = [
        "https://*.foxden.network"
        "https://*.foxden.network:9090"
      ];
    };

    # BELOW FROM NIXPKGS UNSTABLE
    environment.etc = {
      # Add plugins in discoverable folder
      "cockpit/share/cockpit".source = "${
        pkgs.buildEnv {
          name = "cockpit-plugins";
          paths = allPackages;
          pathsToLink = [ "/share/cockpit" ];
        }
      }/share/cockpit";

      # Add plugins dependencies
      "cockpit/bin".source = "${
        pkgs.buildEnv {
          name = "cockpit-path";
          paths = lib.concatMap (p: p.passthru.cockpitPath or [ ]) config.services.cockpit.plugins;
          pathsToLink = [ "/bin" ];
        }
      }/bin";
    };
    # ABOVE FROM NIXPKGS UNSTABLE

    environment.systemPackages = allPackages;
  };
}
