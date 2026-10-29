{
  foxDenLib,
  kanidm,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.syncthing;

  defaultDataDir = "/var/lib/syncthing";
  ifDefaultData = lib.mkIf (svcConfig.dataDir == defaultDataDir);

  guiSocketDir = "/run/syncthing-gui";
  # Inside http-syncthing's private /tmp
  forbiddenSocket = "/tmp/syncthing-forbidden.sock";

  # One instance per login-users member, each with its own sync port, GUI socket and WebDAV root
  users = lib.genAttrs (kanidm.groups.login-users.members or [ ]) (
    user:
    let
      gidNumber = kanidm.persons.${user}.gidNumber or null;
    in
    {
      syncPort = if gidNumber == null then null else 20000 + gidNumber;
      configDir = "${svcConfig.dataDir}/config/${user}";
      folderDir = "${svcConfig.dataDir}/users/${user}";
      guiSocket = "${guiSocketDir}/${user}.sock";
    }
  );

  mkSyncthingConfig =
    user: userCfg:
    pkgs.writeShellScript "syncthing-${user}-config" ''
      set -euo pipefail
      if [ ! -f ${userCfg.configDir}/config.xml ]; then
        ${pkgs.syncthing}/bin/syncthing generate --home=${userCfg.configDir} --no-port-probing
      fi
      ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
        -u /configuration/gui/address -v ${userCfg.guiSocket} \
        -d /configuration/gui/unixSocketPermissions \
        -s /configuration/gui -t elem -n unixSocketPermissions -v 0600 \
        -d /configuration/options/listenAddress \
        -s /configuration/options -t elem -n listenAddress -v tcp://:${toString userCfg.syncPort} \
        -s /configuration/options -t elem -n listenAddress -v quic://:${toString userCfg.syncPort} \
        -u /configuration/options/localAnnounceEnabled -v false \
        -u /configuration/options/startBrowser -v false \
        -u /configuration/defaults/folder/@path -v ${userCfg.folderDir} \
        ${userCfg.configDir}/config.xml
    '';
in
{
  options.foxDen.services.syncthing = {
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = defaultDataDir;
      description = "Directory to store syncthing data";
    };
    syncthingHost = lib.mkOption {
      type = lib.types.str;
      description = "Host to run syncthing in (empty for host)";
    };
    webdavHost = lib.mkOption {
      type = lib.types.str;
      description = "Host to run webdav in (empty for host)";
    };
  }
  // (services.http.mkOptions {
    name = "Syncthing server";
  });

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-syncthing";
        dynamicUser = false;
        modules = [
          pkgs.nginxModules.dav
        ];
        rawConfig =
          { baseWebConfig, proxyConfigNoHost, ... }:
          ''
            ${lib.concatMapAttrsStringSep "\n" (user: userCfg: ''
              upstream syncthing_${user} {
                server unix:${userCfg.guiSocket};
              }
            '') users}

            # auth_request only runs in the access phase, after any rewrite-phase "if",
            # so users without an instance are sent to an upstream that answers 403
            upstream syncthing_forbidden {
              server unix:${forbiddenSocket};
            }
            server {
              listen unix:${forbiddenSocket};
              return 403;
            }

            map $preferred_username $syncthing_upstream {
              default syncthing_forbidden;
            ${lib.concatMapAttrsStringSep "\n" (user: _: "  ${user} syncthing_${user};") users}
            }

            # $remote_user is read from the Authorization header before auth_basic verifies it.
            # Empty falls through to auth_basic (401); a name outside login-users is refused.
            map $remote_user $syncthing_webdav_denied {
              default 1;
              "" 0;
            ${lib.concatMapAttrsStringSep "\n" (user: _: "  ${user} 0;") users}
            }
            # map is case-insensitive, so root on the canonical name rather than $remote_user
            map $remote_user $syncthing_webdav_user {
              default "";
            ${lib.concatMapAttrsStringSep "\n" (user: _: "  ${user} ${user};") users}
            }

            server {
              server_name ${svcConfig.syncthingHost};
              ${baseWebConfig}
              ${services.http.mkNginxHandler pkgs ''
                proxy_pass http://$syncthing_upstream;
                ${proxyConfigNoHost}
                proxy_set_header Host localhost;
              '' svcConfig}
            }
            server {
              server_name ${svcConfig.webdavHost};
              ${baseWebConfig}

              auth_basic "Syncthing WebDAV";
              auth_basic_user_file ${
                if config.foxDen.sops.available then config.sops.secrets.http-syncthing.path else "/dev/null"
              };
              root /syncthing/users/$syncthing_webdav_user;
              # These values must be defined outside of the location block
              # otherwise, WebDAV will somehow ignore them...
              client_body_temp_path /syncthing/tmp;
              client_max_body_size 0;

              location / {
                if ($syncthing_webdav_denied) {
                  return 403;
                }
                autoindex on;
                dav_methods PUT DELETE MKCOL COPY MOVE;
                dav_ext_methods PROPFIND OPTIONS;
                create_full_put_path on;
                dav_access user:rw;
              }
            }
          '';
      }).config
      {
        assertions = lib.mapAttrsToList (user: userCfg: {
          assertion = userCfg.syncPort != null && userCfg.syncPort <= 65535;
          message = "Syncthing user ${user} needs a kanidm gidNumber below 45536 to derive its sync port";
        }) users;

        foxDen.services.kanidm.oauth2.${svcConfig.oAuth.clientId} = lib.mkIf svcConfig.oAuth.enable {
          # The GUI socket is picked by the short username
          preferShortUsername = true;
        };

        foxDen.hosts.hosts.${svcConfig.host}.interfaces.default.firewall.portForwards = lib.concatLists (
          lib.mapAttrsToList (user: userCfg: [
            {
              protocol = "tcp";
              port = userCfg.syncPort;
            }
            {
              protocol = "udp";
              port = userCfg.syncPort;
            }
          ]) users
        );

        users.users.syncthing = {
          isSystemUser = true;
          group = "syncthing";
          uid = config.ids.uids.syncthing;
          home = svcConfig.dataDir;
        };
        users.groups.syncthing.gid = config.ids.gids.syncthing;

        sops.secrets.http-syncthing = config.lib.foxDen.sops.mkIfAvailable {
          mode = "0400";
          owner = "syncthing";
          group = "syncthing";
        };

        systemd.tmpfiles.rules = [
          "d ${guiSocketDir} 0700 syncthing syncthing -"
          "d ${svcConfig.dataDir}/config 0700 syncthing syncthing -"
          "d ${svcConfig.dataDir}/users 0700 syncthing syncthing -"
          "d ${svcConfig.dataDir}/tmp 0700 syncthing syncthing -"
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (user: userCfg: [
            "d ${userCfg.configDir} 0700 syncthing syncthing -"
            "d ${userCfg.folderDir} 0700 syncthing syncthing -"
          ]) users
        );

        systemd.services = {
          http-syncthing = {
            serviceConfig = {
              User = "syncthing";
              Group = "syncthing";
              BindPaths = [
                "${svcConfig.dataDir}:/syncthing"
                guiSocketDir
              ];
              BindReadOnlyPaths = config.lib.foxDen.sops.mkIfAvailable [
                config.sops.secrets.http-syncthing.path
              ];
            };
          };
        }
        // lib.mapAttrs' (
          user: userCfg:
          lib.nameValuePair "syncthing-${user}" (
            lib.mkMerge [
              # Kept under systemd.services so the module's shape doesn't depend on the kanidm user list
              (services.mkNamed "syncthing-${user}" {
                inherit svcConfig pkgs config;
              }).config.systemd.services."syncthing-${user}"
              {
                environment.STNODEFAULTFOLDER = "1";
                serviceConfig = {
                  User = "syncthing";
                  Group = "syncthing";
                  BindPaths = [
                    userCfg.configDir
                    userCfg.folderDir
                    guiSocketDir
                  ];
                  ExecStartPre = [ (mkSyncthingConfig user userCfg) ];
                  ExecStart = "${pkgs.syncthing}/bin/syncthing serve --home=${userCfg.configDir} --no-browser --no-restart --no-upgrade";
                  # 3 = restart requested from the GUI, 4 = upgrade (disabled)
                  SuccessExitStatus = "3 4";
                  RestartForceExitStatus = "3 4";
                  UMask = "0077";
                };
                wantedBy = [ "multi-user.target" ];
              }
            ]
          )
        ) users;

        environment.persistence."/nix/persist/syncthing" = ifDefaultData {
          hideMounts = true;
          directories = [
            {
              directory = defaultDataDir;
              user = "syncthing";
              group = "syncthing";
              mode = "u=rwx,g=,o=";
            }
          ];
        };
      }
    ]
  );
}
