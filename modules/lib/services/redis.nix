{ nixpkgs, foxDenLib, ... }:
{
  make = (inputs@{ config, svcConfig, pkgs, ... }:
    let
      name = "redis-${inputs.name}";
      svc = foxDenLib.services.mkNamed name inputs;
    in
    {
      config = (nixpkgs.lib.mkMerge [
        svc.config
        {
          services.redis.servers.${inputs.name} = {
            enable = true;
            port = 6379;
            bind = "127.0.0.1";
            requirePass = null;
            requirePassFile = null;
          };

          systemd.services.${name} = {
            serviceConfig = {
              StateDirectory = name;
            };
          };

          environment.persistence."/nix/persist/redis" = {
            hideMounts = true;
            directories = [
              { directory = "/var/lib/${inputs.name}"; user = inputs.name; group = inputs.name; mode = "u=rwx,g=rx,o="; }
            ];
          };
        }
      ]);
    });
}
