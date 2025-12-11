{
  lib,
  config,
  foxDenLib,
  ...
}:
{
  options.foxDen.services.kanidm.login = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable kanidm login";
  };

  config = lib.mkIf config.foxDen.services.kanidm.login {
    security.wrappers."kanidm_ssh_authorizedkeys" = {
      source = "${config.services.kanidm.package}/bin/kanidm_ssh_authorizedkeys";
      owner = "root";
      group = "root";
    };

    environment.shells = [
      "/usr/bin/fish"
      "/usr/bin/zsh"
    ];
    systemd.tmpfiles.rules = [
      "L /usr/bin/fish - - - - /run/current-system/sw/bin/fish"
      "L /usr/bin/zsh - - - - /run/current-system/sw/bin/zsh"
    ];

    systemd.services.kanidm-unixd = {
      serviceConfig = {
        BindReadOnlyPaths = [
          "-/run/current-system/sw/bin"
          "-/usr/bin"
        ]
        ++ (foxDenLib.services.mkEtcPaths [
          "shells"
        ]);
      };
    };

    systemd.services.kanidm-unixd-tasks = {
      serviceConfig = {
        BindReadOnlyPaths = foxDenLib.services.mkEtcPaths [
          "passwd"
          "group"
          "shadow"
        ];
      };
    };

    services.openssh = {
      authorizedKeysCommand = "/run/wrappers/bin/kanidm_ssh_authorizedkeys %u";
      authorizedKeysCommandUser = "nobody";
    };

    nix.settings.allowed-users = [ "@wheel" ];

    services.kanidm = {
      enablePam = true;

      unixSettings = {
        version = "2";
        kanidm = {
          pam_allowed_login_groups = [ "login-users" ];
        };
        pam_allowed_login_groups = [ "login-users" ];

        default_shell = "/run/current-system/sw/bin/fish";

        uid_attr_map = "name";
        gid_attr_map = "name";
        home_attr = "name";
        home_alias = "none";

        kanidm.map_group = [
          {
            "local" = "share";
            "with" = "login-users";
          }
          {
            "local" = "wheel";
            "with" = "superadmins";
          }
          {
            "local" = "maintainers";
            "with" = "superadmins";
          }
        ];
      };
    };

    environment.persistence."/nix/persist/system".directories = [
      {
        directory = "/var/cache/kanidm-unixd";
        user = "kanidm-unixd";
        group = "kanidm-unixd";
        mode = "u=rwx,g=,o=";
      }
    ];
  };
}
