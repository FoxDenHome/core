{
  pkgs,
  ...
}:
pkgs.writers.writePython3Bin "kanidm-app-auth" {
  libraries = [ pkgs.python3Packages.ldap3 ];
  # Formatting is ruff's (as in mikrotik/), not flake8's
  doCheck = false;
} (builtins.readFile ./kanidm-app-auth.py)
