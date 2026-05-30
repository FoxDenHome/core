{ pkgs, ... }:
{
  services.kanidm = {
    package = pkgs.kanidmWithSecretProvisioning_1_10;

    client.enable = true;
    client.settings = {
      uri = "https://auth.foxden.network";
      verify_ca = true;
      verify_hostnames = true;
    };
  };
}
