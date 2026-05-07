{ pkgs, ... }:
{
  services.kanidm = {
    enableClient = true;

    package = pkgs.kanidmWithSecretProvisioning_1_10;

    clientSettings = {
      uri = "https://auth.foxden.network";
      verify_ca = true;
      verify_hostnames = true;
    };
  };
}
