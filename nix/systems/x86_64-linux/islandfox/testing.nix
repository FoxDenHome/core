{ pkgs, ... }:
{
  config.systemd.services.failtest = {
    description = "A test service that fails to start";
    serviceConfig = {
      ExecStart = [ "${pkgs.coreutils}/bin/false" ];
      Restart = "no";
    };
  };
}
