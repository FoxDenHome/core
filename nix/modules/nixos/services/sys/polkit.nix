{
  config,
  pkgs,
  lib,
  ...
}:
let
  idents = config.security.polkit.adminIdentities;

  mkIdentCheck = (
    ident:
    let
      identSplit = lib.splitString ":" ident;
      identType = lib.head identSplit;
      identValue = lib.concatStringsSep ":" (lib.tail identSplit);
    in
    (
      if identType == "unix-user" then
        "subject.user == '${identValue}'"
      else if identType == "unix-group" then
        "subject.isInGroup('${identValue}')"
      else
        throw "Unsupported identity type: ${identType}"
    )
  );

  identChecks = lib.concatStringsSep " || " (map mkIdentCheck idents);

  polkitRules = pkgs.writers.writeText "05-foxden.rules" ''
    // Auth as self if in adminIdentities
    // this avoids the unnecessary selection of which identity to use
    polkit.addAdminRule(function(action, subject) {
      if (${identChecks}) {
        return ["unix-user:"+subject.user];
      }
    });
  '';
in
{
  config = {
    systemd.services.polkit.restartTriggers = [ polkitRules ];
    environment.etc."polkit-1/rules.d/05-foxden.rules".source = polkitRules;
  };
}
