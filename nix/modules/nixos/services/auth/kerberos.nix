{
  foxDenLib,
  pkgs,
  lib,
  config,
  kerberos,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.kerberos;
  krbCfg = config.foxDen.kerberos;
  realm = krbCfg.realm;
  hostName = services.getFirstFQDN config svcConfig;

  stateDir = "/var/lib/foxden/kerberos";
  syncKeytab = "${stateDir}/krb5-sync.keytab";
  syncPrincipal = "krb5-sync";
  syncPort = 8088;

  enctypes = lib.concatMapStringsSep " " (e: "${e}:normal") krbCfg.enctypes;

  # Only krb5-sync can change anything remotely, and only these users'
  # passwords. Everything else goes through kadmin.local on the host.
  aclFile = pkgs.writeText "kadm5.acl" (
    lib.concatMapStrings (user: "${syncPrincipal}@${realm} c ${user}@${realm}\n") svcConfig.users
  );

  kdcConf = pkgs.writeText "kdc.conf" ''
    [kdcdefaults]
      kdc_listen = 88
      kdc_tcp_listen = 88

    [realms]
      ${realm} = {
        database_name = ${stateDir}/principal
        key_stash_file = ${stateDir}/stash
        acl_file = ${aclFile}
        # Local only: krb5-sync is the sole remote admin, and users must not
        # set a Kerberos password that differs from their unix one.
        kadmind_listen = 127.0.0.1:749
        kpasswd_listen = 127.0.0.1:464
        supported_enctypes = ${enctypes}
        default_principal_flags = +preauth
        # ksmbd drops SMB sessions when the ticket expires.
        max_life = 1d 0h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
      }

    [logging]
      kdc = STDERR
      admin_server = STDERR
  '';

  # For the tools on this host: talk to the KDC in our own netns.
  krb5Conf = pkgs.writeText "krb5.conf" ''
    [libdefaults]
      default_realm = ${realm}
      dns_lookup_kdc = false
      dns_lookup_realm = false
      rdns = false

    [realms]
      ${realm} = {
        kdc = 127.0.0.1
        admin_server = 127.0.0.1
      }
  '';

  krbEnv = {
    KRB5_CONFIG = "${krb5Conf}";
    KRB5_KDC_PROFILE = "${kdcConf}";
  };

  usersFile = pkgs.writeText "krb5-sync-users" (lib.concatMapStrings (u: "${u}\n") svcConfig.users);

  serviceKeytabs = kerberos.keytabs;

  provision = pkgs.writeShellApplication {
    name = "kerberos-provision";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.krb5
    ];
    text = ''
      q() {
        kadmin.local -r ${realm} -q "$1"
      }
      exists() {
        q "getprinc $1" 2>/dev/null | grep -q '^Principal: '
      }
      # Password twice on stdin, so it stays out of argv.
      set_password() {
        local principal=$1 password=$2
        if exists "$principal"; then
          printf '%s\n%s\n' "$password" "$password" | q "cpw $principal" >/dev/null
        else
          printf '%s\n%s\n' "$password" "$password" | q "addprinc $principal" >/dev/null
        fi
        # Clients derive the key themselves and assume kvno 1.
        q "modprinc -kvno 1 $principal" >/dev/null
      }

      if [ ! -e ${stateDir}/principal ]; then
        echo "Creating realm ${realm}"
        kdb5_util create -s -r ${realm} -P "$(head -c 48 /dev/urandom | base64 -w 0)" >/dev/null
      fi

      managed=" ${lib.concatStringsSep " " svcConfig.users} "
      for user in $managed; do
        if ! exists "$user"; then
          echo "Adding principal $user (no key until the first sync)"
          q "addprinc -randkey $user" >/dev/null
        fi
        q "modprinc +allow_tix $user" >/dev/null
      done

      # Lock user principals that are no longer managed, rather than
      # deleting them.
      q listprincs 2>/dev/null | grep -v / | while read -r principal; do
        user=''${principal%@${realm}}
        if [ "$user" = ${syncPrincipal} ]; then
          continue
        fi
        if [[ "$managed" != *" $user "* ]]; then
          echo "Locking unmanaged principal $user"
          q "modprinc -allow_tix $user" >/dev/null
        fi
      done

      ${lib.concatStrings (
        lib.mapAttrsToList (name: keytab: ''
          secret="$CREDENTIALS_DIRECTORY/${keytab.secret}"
          if [ -r "$secret" ]; then
            ${lib.concatMapStrings (principal: ''
              set_password ${lib.escapeShellArg principal} "$(cat "$secret")"
            '') keytab.principals}
          else
            echo "No secret for keytab ${name}, skipping its principals" >&2
          fi
        '') serviceKeytabs
      )}

      if ! exists ${syncPrincipal}; then
        q "addprinc -randkey ${syncPrincipal}" >/dev/null
      fi
      if [ ! -s ${syncKeytab} ]; then
        q "ktadd -k ${syncKeytab} ${syncPrincipal}" >/dev/null
      fi
    '';
  };

  commonServiceConfig = {
    User = "kerberos";
    Group = "kerberos";
    BindPaths = [ stateDir ];
  };
in
{
  options.foxDen.services.kerberos =
    (services.http.mkOptions {
      name = "Kerberos KDC and password sync";
    })
    // {
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.attrNames (
          lib.filterAttrs (_: p: p.present && p.enableUnix) config.services.kanidm.provision.persons
        );
        description = "Users that get a principal and may sync their unix password into it.";
      };
    };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "kerberos-kdc";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "kerberos-kadmind";
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "krb5-sync";
        inherit svcConfig pkgs config;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-krb5-sync";
        target = "proxy_pass http://127.0.0.1:${toString syncPort};";
        # For PAM hooks on clients: authenticates with the password itself,
        # so it can't sit behind OAuth. LAN only.
        extraConfig =
          { proxyConfig, ... }:
          ''
            location = /api/sync {
              allow 10.0.0.0/8;
              allow fd2c:f4cb:63be::/48;
              deny all;
              ${proxyConfig}
              proxy_pass http://127.0.0.1:${toString syncPort};
            }
          '';
      }).config
      {
        foxDen.kerberos.enable = true;

        # krb5-sync takes the username from preferred_username.
        foxDen.services.kanidm.oauth2 = lib.mkIf svcConfig.oAuth.enable {
          ${svcConfig.oAuth.clientId}.preferShortUsername = true;
        };

        users.users.kerberos = {
          isSystemUser = true;
          group = "kerberos";
        };
        users.groups.kerberos = { };

        sops.secrets = config.lib.foxDen.sops.mkIfAvailable (
          lib.mapAttrs' (_: keytab: lib.nameValuePair keytab.secret { }) serviceKeytabs
        );

        systemd.services.kerberos-kdc = {
          description = "Kerberos KDC";
          wantedBy = [ "multi-user.target" ];
          restartTriggers = [ kdcConf ];
          environment = krbEnv;
          confinement.packages = [
            krb5Conf
            kdcConf
          ];
          serviceConfig = commonServiceConfig // {
            LoadCredential = config.lib.foxDen.sops.mkIfAvailable (
              lib.mapAttrsToList (
                _: keytab: "${keytab.secret}:${config.sops.secrets.${keytab.secret}.path}"
              ) serviceKeytabs
            );
            ExecStartPre = lib.getExe provision;
            ExecStart = "${pkgs.krb5}/bin/krb5kdc -n";
          };
        };

        systemd.services.kerberos-kadmind = {
          description = "Kerberos admin server (local only)";
          wantedBy = [ "multi-user.target" ];
          requires = [ "kerberos-kdc.service" ];
          after = [ "kerberos-kdc.service" ];
          restartTriggers = [
            kdcConf
            aclFile
          ];
          environment = krbEnv;
          confinement.packages = [
            krb5Conf
            kdcConf
          ];
          serviceConfig = commonServiceConfig // {
            ExecStart = "${pkgs.krb5}/bin/kadmind -nofork";
          };
        };

        systemd.services.krb5-sync = {
          description = "Kerberos password sync from kanidm";
          wantedBy = [ "multi-user.target" ];
          requires = [ "kerberos-kadmind.service" ];
          after = [ "kerberos-kadmind.service" ];
          environment.KRB5_CONFIG = "${krb5Conf}";
          confinement.packages = [ krb5Conf ];
          serviceConfig = {
            DynamicUser = true;
            LoadCredential = "keytab:${syncKeytab}";
            # kadmin wants a writable replay cache and ccache location
            PrivateTmp = true;
            ExecStart = lib.escapeShellArgs [
              (lib.getExe pkgs.krb5-sync)
              "-listen"
              "127.0.0.1:${toString syncPort}"
              "-realm"
              realm
              "-users-file"
              usersFile
              "-kadmin"
              "${pkgs.krb5}/bin/kadmin"
              "-principal"
              syncPrincipal
              "-keytab"
              "%d/keytab"
            ];
          };
        };

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0700 kerberos kerberos - -"
        ];

        foxDen.hosts.hosts.${svcConfig.host}.interfaces.default.firewall.ingressAcceptRules =
          lib.concatMap
            (protocol: [
              {
                inherit protocol;
                source = "10.0.0.0/8";
                port = 88;
                comment = "kerberos-kdc";
              }
              {
                inherit protocol;
                source = "fd2c:f4cb:63be::/48";
                port = 88;
                comment = "kerberos-kdc";
              }
            ])
            [
              "tcp"
              "udp"
            ];

        foxDen.dns.records =
          let
            domain = lib.toLower realm;
            mkSrv = proto: {
              fqdn = "_kerberos._${proto}.${domain}";
              type = "SRV";
              ttl = 3600;
              port = 88;
              priority = 0;
              weight = 0;
              value = "${hostName}.";
              horizon = "internal";
            };
          in
          [
            (mkSrv "udp")
            (mkSrv "tcp")
            {
              fqdn = "_kerberos.${domain}";
              type = "TXT";
              ttl = 3600;
              value = realm;
              horizon = "internal";
            }
          ];
      }
    ]
  );
}
