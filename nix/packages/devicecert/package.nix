{
  pkgs,
  ...
}:
pkgs.writers.writePython3Bin "devicecert" {
  libraries = [ pkgs.python3Packages.cryptography ];
  # Formatting is ruff's (as in mikrotik/), not flake8's
  doCheck = false;
} (builtins.readFile ./devicecert.py)
