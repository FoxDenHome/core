{ ... }:
{
  home-manager.users.root =
    { ... }:
    {
      home.stateVersion = "25.11";

      programs.gpg.scdaemonSettings = {
        disable-ccid = true;
        pcsc-shared = true;
      };
    };
}
