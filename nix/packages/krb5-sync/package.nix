{
  lib,
  pkgs,
  ...
}:
pkgs.buildGoModule {
  pname = "krb5-sync";
  version = "1.0.0";

  src = ./.;
  vendorHash = null;

  meta = {
    description = "Sets Kerberos keys from verified kanidm unix passwords";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = lib.platforms.linux;
    mainProgram = "krb5-sync";
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
