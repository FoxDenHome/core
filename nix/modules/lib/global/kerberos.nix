{ foxDenLib, ... }:
{
  mkConfig = nixosConfigurations: {
    keytabs = foxDenLib.global.config.getAttrSet [
      "foxDen"
      "kerberos"
      "keytabs"
    ] nixosConfigurations;
  };
}
