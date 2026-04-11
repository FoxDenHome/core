{
  pkgs,
  lib,
  config,
  ...
}:
let
  svcConfig = config.foxDen.services.netdata;

  mkDir = (
    dir: {
      directory = dir;
      user = config.services.netdata.user;
      group = config.services.netdata.group;
      mode = "u=rwx,g=,o=";
    }
  );
in
{
  options.foxDen.services.netdata = {
    enable = lib.mkEnableOption "netdata";
  };

  config = lib.mkIf svcConfig.enable {
    services.netdata = {
      enable = true;
      package = pkgs.netdata.override {
        withCloudUi = true;
        withIpmi = false;
      };

      # https://www.netdata.cloud/blog/systemd-service-liveness/
      configDir."go.d/systemdunits.conf" = pkgs.writeText "systemdunits.conf" ''
        jobs:
          - name: all-services
            include:
              - '*.service'
      '';

      configDir."health.d/systemdunits.conf" = pkgs.writeText "systemdunits-health.conf" ''
         template: systemd_service_unit_failed_state
               on: systemd.service_unit_state
            class: Errors
             type: Linux
        component: Systemd units
             calc: $failed
            units: state
            every: 10s
             warn: $this != nan AND $this == 1
            delay: down 3m multiplier 1.5 max 1h
             info: systemd service $\{label:unit_name\} in the failed state
               to: sysadmin
      '';
    };
    environment.persistence."/nix/persist/netdata" = {
      hideMounts = true;
      directories = [
        (mkDir "/var/lib/netdata")
        (mkDir "/var/cache/netdata")
      ];
    };
  };
}
