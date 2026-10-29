{ foxDenLib, nixpkgs, ... }:
{
  mkConfig = nixosConfigurations: {
    oauth2 = foxDenLib.global.config.getAttrSet [
      "foxDen"
      "services"
      "kanidm"
      "oauth2"
    ] nixosConfigurations;
    persons = foxDenLib.global.config.getAttrSet [
      "services"
      "kanidm"
      "provision"
      "persons"
    ] nixosConfigurations;
    groups = foxDenLib.global.config.getAttrSet [
      "services"
      "kanidm"
      "provision"
      "groups"
    ] nixosConfigurations;
    externalIPs = nixpkgs.lib.lists.uniqueStrings (
      foxDenLib.global.config.getList [ "foxDen" "services" "kanidm" "externalIPs" ] nixosConfigurations
    );
  };
}
