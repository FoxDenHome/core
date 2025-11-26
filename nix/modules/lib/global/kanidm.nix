{ foxDenLib, nixpkgs, ... }:
{
  mkConfig = nixosConfigurations: {
    oauth2 = foxDenLib.global.config.getAttrSet [
      "foxDen"
      "services"
      "kanidm"
      "oauth2"
    ] nixosConfigurations;
    externalIPs = nixpkgs.lib.lists.uniqueStrings (
      foxDenLib.global.config.getList [ "foxDen" "services" "kanidm" "externalIPs" ] nixosConfigurations
    );
  };
}
