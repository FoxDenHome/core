{
  config,
  pkgs,
  lib,
  ...
}:
let
  pathPkgs = [ config.services.cockpit.package ] ++ config.services.cockpit.plugins;

  resourcesEnv = pkgs.buildEnv {
    name = "cockpit-plugins";
    paths = pathPkgs;
    pathsToLink = [ "/share/cockpit" ];
  };

  depsEnv = pkgs.buildEnv {
    name = "cockpit-plugins-env";
    paths = lib.concatMap (p: p.passthru.cockpitPath or [ ]) pathPkgs;
    pathsToLink = [
      "/bin"
      "/share"
      "/lib"
    ];
  };

  share = pkgs.buildEnv {
    name = "cockpit-share";
    paths = [
      resourcesEnv
      depsEnv
    ];
    pathsToLink = [ "/share" ];
  };
in
{
  # BELOW FROM NIXPKGS UNSTABLE
  options.services.cockpit.plugins = lib.mkOption {
    type = with lib.types; listOf path;
    default = [ ];
    description = "Cockpit plugins to enable.";
  };
  # ABOVE FROM NIXPKGS UNSTABLE

  config = lib.mkIf config.services.cockpit.enable {
    services.cockpit = {
      openFirewall = true;
      package = pkgs.pkgsUnstable.cockpit;
      allowed-origins = [
        "https://*.foxden.network"
        "https://*.foxden.network:9090"
      ];
    };

    # BELOW FROM NIXPKGS UNSTABLE
    environment.etc = {
      "cockpit/share".source = "${share}/share";

      # Add plugins dependencies
      "cockpit/bin".source = "${depsEnv}/bin";
      "cockpit/lib".source = "${depsEnv}/lib";
    };
    # ABOVE FROM NIXPKGS UNSTABLE

    environment.systemPackages = pathPkgs;
  };
}
