{
  lib,
  config,
  sops-nix,
  ...
}:
let
  sharedSopsFile = ../../secrets/shared.yaml;

  mkIfAvailable = lib.mkIf config.foxDen.sops.available;
  mkGithubTokenPath = mkIfAvailable config.sops.secrets."github-token-env".path;
in
{
  imports = [
    sops-nix.nixosModules.sops
  ];

  options.foxDen.sops.available = lib.mkEnableOption "Enable sops-nix usage";

  config = lib.mkMerge [
    {
      lib.foxDen.sops = {
        inherit mkIfAvailable mkGithubTokenPath;
      };
    }
    (mkIfAvailable {
      sops.secrets."root-password-hash" = {
        neededForUsers = true;
      };

      sops.secrets."github-token-env" = {
        sopsFile = sharedSopsFile;
      };

      users.mutableUsers = false;

      users.users.root.hashedPasswordFile = config.sops.secrets."root-password-hash".path;

      nix.extraOptions = ''
        !include ${config.sops.secrets."nix-config".path}
      '';
      sops.secrets."nix-config" = {
        sopsFile = sharedSopsFile;
      };
    })
  ];
}
