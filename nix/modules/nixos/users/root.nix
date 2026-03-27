{ config, ... }:
{
  home-manager.users.root =
    { ... }:
    {
      home.stateVersion = config.system.stateVersion;

      programs.gpg = {
        enable = true;
        scdaemonSettings = {
          disable-ccid = true;
          pcsc-shared = true;
        };
      };
    };
}
