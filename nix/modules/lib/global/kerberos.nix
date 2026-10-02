{ foxDenLib, nixpkgs, ... }:
{
  mkConfig = nixosConfigurations: {
    keytabs = foxDenLib.global.config.getAttrSet [
      "foxDen"
      "kerberos"
      "keytabs"
    ] nixosConfigurations;
    # Users with a principal on the KDC, for services mapping them locally.
    # SMB servers' client descriptors (foxDen.services.ksmbd.clients).
    smbServers = nixpkgs.lib.filter (x: x != null) (
      foxDenLib.global.config.getList [ "foxDen" "services" "ksmbd" "clients" ] nixosConfigurations
    );
    users = nixpkgs.lib.lists.unique (
      foxDenLib.global.config.getList [ "foxDen" "services" "kerberos" "users" ] nixosConfigurations
    );
  };
}
