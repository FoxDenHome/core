{
  lib,
  config,
  pkgs,
  ...
}:
let
  rsaKeyFile = "/nix/persist/foxden/bootssh/ssh_host_rsa_key";
  ed25519KeyFile = "/nix/persist/foxden/bootssh/ssh_host_ed25519_key";
in
{
  options.foxDen.services.bootssh = {
    enable = lib.mkEnableOption "bootssh";
  };
  config = lib.mkIf config.foxDen.services.bootssh.enable {
    boot.initrd.network.ssh = {
      enable = true;
      port = 4; # 2+2 :3
      authorizedKeys.keys = [
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBN/lwUU7uvM/G/4HdEg4SJ2YaEq2SK8mwMcdPmRZBQ6w4+RykvUAJi3cVLBeI8Ng3vW3faDIW2HU2P4qF4y+kDM= doridian@fennec"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNhmxwlcA26Dee8lNV3rSDxZeC+Q8xDC80iwLDO9d9smSZ4qBAcLGZrjV4mRyVI0omNG/VyB10VCQrS52E+QqrQ= doridian@capefox"
      ];
      hostKeys = [
        rsaKeyFile
        ed25519KeyFile
      ];
    };
    boot.initrd.systemd = {
      users.root.shell = "/bin/bash";
      storePaths = with pkgs; [
        bash
        cryptsetup
      ];
    };
    system.activationScripts.bootsshKeygen = {
      text = ''
        mkdir -p /nix/persist/foxden/bootssh
        if [ ! -f ${rsaKeyFile} ]; then
          ssh-keygen -t rsa -N "" -f ${rsaKeyFile}
        fi
        if [ ! -f ${ed25519KeyFile} ]; then
          ssh-keygen -t ed25519 -N "" -f ${ed25519KeyFile}
        fi
      '';
      deps = [
        "users"
      ];
    };
  };
}
