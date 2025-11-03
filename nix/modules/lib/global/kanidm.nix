{ foxDenLib, nixpkgs, ... }:
{
  mkConfig = nixosConfigurations: {
    oauth2 = foxDenLib.global.config.getAttrSet [ "foxDen" "services" "kanidm" "oauth2" ] nixosConfigurations;
    # TODO: Go back to uniqueStrings once next NixOS stable
    externalIPs = nixpkgs.lib.lists.unique (foxDenLib.global.config.getList [ "foxDen" "services" "kanidm" "externalIPs" ] nixosConfigurations);
  };
}
