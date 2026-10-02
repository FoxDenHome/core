{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.foxDen.kerberos;

  keytabDir = "/run/krb5-keytabs";

  # Rebuilds a keytab from a password shared with the KDC through sops.
  # Both sides derive the same keys from it (default salt, kvno 1), so the
  # keytab never has to be copied off the KDC.
  mkKeytabScript =
    name: keytab:
    pkgs.writeShellApplication {
      name = "krb5-keytab-${name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.krb5
      ];
      text = ''
        password=$(cat "$CREDENTIALS_DIRECTORY/secret")
        out=${keytab.path}
        rm -f "$out.new"
        {
        ${lib.concatMapStrings (
          principal:
          lib.concatMapStrings (enctype: ''
            echo "addent -password -p ${principal}@${cfg.realm} -k 1 -e ${enctype}"
            printf '%s\n' "$password"
          '') cfg.enctypes
        ) keytab.principals}
          echo "wkt $out.new"
          echo "quit"
        } | ktutil >/dev/null
        chmod 0600 "$out.new"
        mv -f "$out.new" "$out"
      '';
    };
in
{
  options.foxDen.kerberos = with lib.types; {
    enable = lib.mkEnableOption "the FoxDen Kerberos realm in /etc/krb5.conf";
    realm = lib.mkOption {
      type = str;
      default = "FOXDEN.NETWORK";
    };
    kdc = lib.mkOption {
      type = str;
      default = "kerberos.foxden.network";
    };
    enctypes = lib.mkOption {
      type = listOf str;
      # SHA-1 variants only, for macOS (Heimdal) clients.
      default = [
        "aes256-cts-hmac-sha1-96"
        "aes128-cts-hmac-sha1-96"
      ];
      description = "Key types for principals and generated keytabs. The KDC and every keytab must agree.";
    };
    keytabs = lib.mkOption {
      type = attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              principals = lib.mkOption {
                type = listOf str;
                example = [ "cifs/nas.foxden.network" ];
                description = "Principals (without realm). The KDC creates them from the same secret.";
              };
              secret = lib.mkOption {
                type = str;
                default = "krb5-keytab-${name}";
                description = "sops key holding the password. Must exist, with the same value, on the KDC host too.";
              };
              path = lib.mkOption {
                type = str;
                readOnly = true;
                default = "${keytabDir}/${name}.keytab";
              };
              unit = lib.mkOption {
                type = str;
                readOnly = true;
                default = "krb5-keytab-${name}.service";
              };
            };
          }
        )
      );
      default = { };
      description = "Keytabs to build on this host. Collected globally so the KDC creates the matching principals.";
    };
  };

  config = lib.mkIf cfg.enable {
    security.krb5 = {
      enable = true;
      settings = {
        libdefaults = {
          default_realm = cfg.realm;
          dns_lookup_kdc = false;
          dns_lookup_realm = false;
          dns_canonicalize_hostname = false;
          rdns = false;
        };
        realms.${cfg.realm} = {
          kdc = [ cfg.kdc ];
        };
        domain_realm = {
          ${lib.toLower cfg.realm} = cfg.realm;
          ".${lib.toLower cfg.realm}" = cfg.realm;
        };
      };
    };

    systemd.tmpfiles.rules = lib.mkIf (cfg.keytabs != { }) [
      "d ${keytabDir} 0700 root root - -"
    ];

    sops.secrets = config.lib.foxDen.sops.mkIfAvailable (
      lib.mapAttrs' (_: keytab: lib.nameValuePair keytab.secret { }) cfg.keytabs
    );

    systemd.services = config.lib.foxDen.sops.mkIfAvailable (
      lib.mapAttrs' (
        name: keytab:
        lib.nameValuePair "krb5-keytab-${name}" {
          description = "Build Kerberos keytab ${name}";
          after = [ "systemd-tmpfiles-setup.service" ];
          restartTriggers = [ (mkKeytabScript name keytab) ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            LoadCredential = "secret:${config.sops.secrets.${keytab.secret}.path}";
            ExecStart = lib.getExe (mkKeytabScript name keytab);
          };
        }
      ) cfg.keytabs
    );
  };
}
