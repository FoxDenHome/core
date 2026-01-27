{ ... }:
{
  home-manager.users.root =
    { ... }:
    {
      home.stateVersion = "25.11";

      programs.gpg = {
        enable = true;
        scdaemonSettings = {
          disable-ccid = true;
          pcsc-shared = true;
        };
      };
    };
}
