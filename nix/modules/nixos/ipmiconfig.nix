{
  lib,
  pkgs,
  foxDenLib,
  config,
  hostName,
  ...
}:
let
  netConfigFamily =
    ipWithCidr: ipWithoutCidr:
    with lib.types;
    submodule {
      options = {
        address = lib.mkOption {
          type = nullOr ipWithCidr;
          default = null;
        };
        gateway = lib.mkOption {
          type = nullOr ipWithoutCidr;
          default = null;
        };
      };
    };
in
{
  options.foxDen.ipmiconfig = with lib.types; {
    enable = lib.mkEnableOption "Enable IPMI configuration management";
    network = {
      hostName = lib.mkOption {
        type = str;
        default = "${hostName}-ipmi";
      };
      hostZone = lib.mkOption {
        type = str;
        default = "foxden.network";
      };
      interface = lib.mkOption {
        type = enum [
          "shared"
          "dedicated"
          "failover"
        ];
        default = "dedicated";
      };
      mac = lib.mkOption {
        type = str;
      };
      vlan = lib.mkOption {
        type = nullOr int;
        default = null;
        description = "VLAN (from routers.nix) the BMC is on. Defaults the IPv4 gateway, DNS and NTP servers.";
      };
      ipv4 = lib.mkOption {
        type = netConfigFamily foxDenLib.types.ipv4WithCidr foxDenLib.types.ipv4WithoutCidr;
        default = { };
      };
      ipv6 = lib.mkOption {
        type = netConfigFamily foxDenLib.types.ipv6WithCidr foxDenLib.types.ipv6WithoutCidr;
        default = { };
      };
      dns = lib.mkOption {
        type = listOf foxDenLib.types.ipv4WithoutCidr;
        default = [ ];
      };
      ntp = lib.mkOption {
        type = listOf foxDenLib.types.ipv4WithoutCidr;
        default = [ ];
      };
    };
    acme.enable = lib.mkEnableOption ''
      a Let's Encrypt certificate for the BMC's web UI. DNS-01 goes through the
      dynamic TXT record _acme-challenge.<hostName>.<hostZone> at dns.he.net. The
      ipmiconfig-acme secret holds its DDNS key as
      HURRICANE_TOKENS=<hostName>.<hostZone>:<key> (tofu output he_dynamic_keys)
    '';
    # BMC user for this host to log in to Redfish with, managed over the KCS
    user = {
      name = lib.mkOption {
        type = str;
        default = "ipmiconfig";
      };
      passwordFile = lib.mkOption {
        type = nullOr str;
        default = null;
        description = "1-16 alphanumeric characters. Without it, the user and the Redfish settings are left alone.";
      };
    };
  };

  config =
    let
      ipmiconfig = config.foxDen.ipmiconfig;
      netconfig = ipmiconfig.network;
      user = ipmiconfig.user;

      vlanConfig = lib.findFirst (
        vlan: vlan.vlanId == netconfig.vlan
      ) (throw "ipmiconfig: VLAN ${toString netconfig.vlan} not in routers.nix") foxDenLib.routers.vlans;

      # 10.<vlan>.X.Y maps to <ula>:<vlan>::<X in hex><Y in two hex digits>,
      # like 10.1.12.1 -> fd2c:f4cb:63be:1::c01
      ipv6FromIpv4 =
        let
          octets = map lib.toInt (lib.splitString "." (foxDenLib.util.removeIPCidr netconfig.ipv4.address));
          hex = n: lib.toLower (lib.toHexString n);
        in
        "${lib.removeSuffix "/64" vlanConfig.ipv6.network}${hex (lib.elemAt octets 2)}${
          lib.fixedWidthString 2 "0" (hex (lib.elemAt octets 3))
        }/64";

      # Response byte of the Supermicro OEM "get LAN interface mode" command
      rawInterfaceModeMap = {
        dedicated = "00";
        shared = "01";
        failover = "02";
      };

      ipv4Address = foxDenLib.util.removeIPCidr netconfig.ipv4.address;
      ipv4Netmask = foxDenLib.util.ipv4Netmask netconfig.ipv4.address;
      ipv6Static = "enable ${lib.replaceString "/" " " netconfig.ipv6.address}";
      interfaceMode = rawInterfaceModeMap.${netconfig.interface};

      oemNtp = {
        NTPEnable = true;
        PrimaryNTPServer = lib.elemAt netconfig.ntp 0;
        SecondaryNTPServer = lib.elemAt netconfig.ntp (if lib.length netconfig.ntp > 1 then 1 else 0);
      };

      redfishEnabled =
        user.passwordFile != null
        && netconfig.ipv4.address != null
        && (netconfig.dns != [ ] || netconfig.ntp != [ ]);

      fqdn = "${netconfig.hostName}.${netconfig.hostZone}";
      certDir = "/var/lib/acme/${fqdn}";
      # Without sops there is no DDNS key, and so no certificate
      certEnabled = ipmiconfig.acme.enable && config.foxDen.sops.available;

      # Each ipmitool call takes superfan's IPMI lock on its own, so the fan
      # control loop never waits long for the KCS. Settings are only written
      # when the BMC reports a different value: needless writes can crash or
      # reboot it. A read that fails aborts the script, and a value that reads
      # back empty is skipped, so neither turns into a write.
      configScript = pkgs.writeShellScript "ipmiconfig.sh" ''
        set -euo pipefail

        ipmi() {
          ipmilocked ipmitool "$@"
        }

        # "key : value" lines, as printed by "lan print" and "channel getaccess"
        colonval() {
          awk -F ' *: ' -v key="$1" '$1 == key { print $2; exit }' <<<"$2"
        }

        failed=0
        ensure() {
          local name="$1" current="$2" desired="$3"
          shift 3
          if [ "$current" = "$desired" ]; then
            echo "$name: $current"
          elif [ -z "$current" ]; then
            echo "$name: could not parse current value, not touching it" >&2
            failed=1
          else
            echo "$name: $current -> $desired"
            ipmi "$@"
          fi
        }

        ${lib.optionalString (netconfig.ipv4.address != null) ''
          lan="$(ipmi lan print 1)"
          ensure "IPv4 source" "$(colonval 'IP Address Source' "$lan")" "Static Address" \
            lan set 1 ipsrc static
          ensure "IPv4 address" "$(colonval 'IP Address' "$lan")" "${ipv4Address}" \
            lan set 1 ipaddr ${ipv4Address}
          ensure "IPv4 netmask" "$(colonval 'Subnet Mask' "$lan")" "${ipv4Netmask}" \
            lan set 1 netmask ${ipv4Netmask}
          ${lib.optionalString (netconfig.ipv4.gateway != null) ''
            ensure "IPv4 gateway" "$(colonval 'Default Gateway IP' "$lan")" "${netconfig.ipv4.gateway}" \
              lan set 1 defgw ipaddr ${netconfig.ipv4.gateway}
          ''}
        ''}

        ${lib.optionalString (netconfig.ipv6.address != null) ''
          # "lan6 save" prints each parameter as the "lan6 set" line that would restore it
          lan6val() {
            local out
            out="$(ipmi lan6 save 1 "$@")"
            sed -n "s/^lan6 set 1 nolock $* //p" <<<"$out"
          }
          enables="$(lan6val enables)"
          # Drop the address status (active, pending, ...) at the end
          static="$(lan6val static_addr 0)"
          static="$(cut -d' ' -f1-3 <<<"$static")"
          rtrcfg="$(lan6val rtr_cfg)"
          ensure "IPv6 enables" "$enables" "both" \
            lan6 set 1 nolock enables both
          ensure "IPv6 static address" "$static" "${ipv6Static}" \
            lan6 set 1 nolock static_addr 0 ${ipv6Static}
          ensure "IPv6 router config" "$rtrcfg" "dynamic" \
            lan6 set 1 nolock rtr_cfg dynamic
        ''}

        mode="$(ipmi raw 0x30 0x70 0x0c 0)"
        mode="$(tr -d ' \n' <<<"$mode")"
        ensure "Interface mode (${netconfig.interface})" "$mode" "${interfaceMode}" \
          raw 0x30 0x70 0x0c 1 0x${interfaceMode}

        mcid="$(ipmi dcmi get_mc_id_string)"
        mcid="$(sed -n 's/^ Get Management Controller Identifier String: //p' <<<"$mcid")"
        ensure "MC ID string" "$mcid" "${netconfig.hostName}" \
          dcmi set_mc_id_string "${netconfig.hostName}"

        ${lib.optionalString (user.passwordFile != null) ''
          # The password only ever goes to ipmitool and curl through files in
          # the runtime directory, never on a command line
          trap 'rm -f "$RUNTIME_DIRECTORY"/*' EXIT
          password="$(<${lib.escapeShellArg user.passwordFile})"
          if ! [[ "$password" =~ ^[A-Za-z0-9]{1,16}$ ]]; then
            echo "BMC user: password must be 1-16 alphanumeric characters" >&2
            exit 1
          fi
          ipmiexec() {
            printf '%s\n' "$1" >"$RUNTIME_DIRECTORY/ipmi-exec"
            ipmi exec "$RUNTIME_DIRECTORY/ipmi-exec"
          }

          # Reuse the slot already named ${user.name}, or claim the highest empty
          # one: other users (ADMIN, fwupd, ...) fill up the low slots. Slot 1
          # is the anonymous user and always has an empty name.
          users="$(ipmi -c user list 1)"
          if ! grep -q '^2,' <<<"$users"; then
            echo "BMC user: could not parse user list, not touching it" >&2
            exit 1
          fi
          uid="$(awk -F , '$2 == "${user.name}" { print $1; exit }' <<<"$users")"
          claimed=0
          if [ -n "$uid" ]; then
            echo "BMC user $uid: ${user.name}"
          else
            uid="$(awk -F , '$1 > 2 && $2 == "" { uid = $1 } END { print uid }' <<<"$users")"
            if [ -z "$uid" ]; then
              echo "BMC user: no empty slot left for ${user.name}" >&2
              exit 1
            fi
            echo "BMC user $uid: claiming empty slot as ${user.name}"
            ipmi user set name "$uid" "${user.name}"
            claimed=1
          fi
          access="$(ipmi channel getaccess 1 "$uid")"
          if [ "$(colonval 'User ID' "$access")" != "$uid" ]; then
            echo "BMC user $uid: could not parse its access, not touching it" >&2
            exit 1
          fi

          # "user test" checks the password without changing anything
          pwtest="$(ipmiexec "user test $uid 16 $password")" || true
          case "$pwtest" in
            *Success*)
              echo "BMC user password: matches"
              ;;
            *"Failure: password incorrect"* | *"Failure: wrong password size"*)
              echo "BMC user password: differs, setting it"
              ipmiexec "user set password $uid $password 16" >/dev/null
              ;;
            *)
              echo "BMC user password: could not test it ($pwtest), not touching it" >&2
              failed=1
              ;;
          esac

          ensure "BMC user privilege" "$(colonval 'Privilege Level' "$access")" "ADMINISTRATOR" \
            channel setaccess 1 "$uid" privilege=4
          ensure "BMC user IPMI messaging" "$(colonval 'IPMI Messaging' "$access")" "enabled" \
            channel setaccess 1 "$uid" ipmi=on

          # Many BMCs report "unknown" here. Only enable a user we did not
          # just create when the BMC says it is disabled.
          enabled="$(colonval 'Enable Status' "$access")"
          if [ "$enabled" = "disabled" ] || [ "$claimed" = 1 ]; then
            echo "BMC user enable status: $enabled -> enabled"
            ipmi user enable "$uid"
          else
            echo "BMC user enable status: $enabled"
          fi
        ''}

        ${lib.optionalString redfishEnabled ''
          printf 'user = "%s:%s"\n' "${user.name}" "$password" >"$RUNTIME_DIRECTORY/curl.conf"
          # The BMC's certificate is self-signed
          redfish() {
            curl --silent --show-error --fail --insecure --config "$RUNTIME_DIRECTORY/curl.conf" "$@"
          }

          # The BMC may still be bringing its network back up after the changes above
          redfishget() {
            redfish --retry 6 --retry-all-errors --retry-delay 10 \
              --dump-header "$RUNTIME_DIRECTORY/headers" "https://${ipv4Address}$1" |
              jq -cS "$2"
          }

          # Only PATCHes when the (normalized) current value differs, and
          # checks that the BMC took it, so it does not get rewritten every run
          redfishensure() {
            local name="$1" path="$2" filter="$3" desired patch current etag
            desired="$(jq -cS . <<<"$4")"
            patch="$5"
            current="$(redfishget "$path" "$filter")"
            if [ "$current" = "$desired" ]; then
              echo "$name: $current"
              return
            elif [ "$current" = null ]; then
              echo "$name: not supported by the BMC, skipping it" >&2
              return
            fi
            echo "$name: $current -> $desired"
            etag="$(sed -n 's/^etag: *//Ip' "$RUNTIME_DIRECTORY/headers" | tail -n 1 | tr -d '\r')"
            redfish --request PATCH --header 'Content-Type: application/json' \
              ''${etag:+--header "If-Match: $etag"} \
              --data "$patch" "https://${ipv4Address}$path" >/dev/null
            current="$(redfishget "$path" "$filter")"
            if [ "$current" != "$desired" ]; then
              echo "$name: BMC reports $current after setting it" >&2
              failed=1
            fi
          }

          ${lib.optionalString (netconfig.ntp != [ ]) ''
            # Older Supermicro firmware (like X10) only has NTP as an OEM resource
            # with exactly two server fields
            if [ "$(redfishget /redfish/v1/Managers/1/NetworkProtocol '.NTP != null')" = true ]; then
              redfishensure "NTP" /redfish/v1/Managers/1/NetworkProtocol \
                '.NTP | {ProtocolEnabled, NTPServers: ((.NTPServers // []) | map(select(. != "")))}' \
                ${
                  lib.escapeShellArg (
                    builtins.toJSON {
                      ProtocolEnabled = true;
                      NTPServers = netconfig.ntp;
                    }
                  )
                } \
                ${lib.escapeShellArg (
                  builtins.toJSON {
                    NTP = {
                      ProtocolEnabled = true;
                      NTPServers = netconfig.ntp;
                    };
                  }
                )}
            else
              redfishensure "NTP" /redfish/v1/Managers/1/NTP \
                '{NTPEnable, PrimaryNTPServer, SecondaryNTPServer}' \
                ${lib.escapeShellArg (builtins.toJSON oemNtp)} \
                ${lib.escapeShellArg (builtins.toJSON oemNtp)}
            fi
          ''}

          ${lib.optionalString (netconfig.dns != [ ]) ''
            # Before EthernetInterface v1.4 there is only the read-only NameServers
            redfishensure "DNS" /redfish/v1/Managers/1/EthernetInterfaces/1 \
              '.StaticNameServers | if . == null then null else map(select(. != "" and . != "0.0.0.0")) end' \
              ${lib.escapeShellArg (builtins.toJSON netconfig.dns)} \
              ${lib.escapeShellArg (builtins.toJSON { StaticNameServers = netconfig.dns; })}
          ''}
        ''}

        exit $failed
      '';

      # Older Supermicro BMCs (like X10) have no Redfish CertificateService, so
      # this goes through the web UI's CGIs. The BMC is only touched when it
      # serves a different certificate than the one lego has, and it needs a
      # reset to pick up the new one.
      certScript = pkgs.writeShellScript "ipmiconfig-cert.sh" ''
        set -euo pipefail
        trap 'rm -f "$RUNTIME_DIRECTORY"/*' EXIT

        fingerprint() {
          openssl x509 -noout -fingerprint -sha256
        }
        served() {
          openssl s_client -connect ${ipv4Address}:443 </dev/null 2>/dev/null | fingerprint
        }

        # Until lego has a certificate, the directory holds a self-signed
        # placeholder
        if ! openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
          -untrusted ${certDir}/chain.pem ${certDir}/cert.pem >/dev/null 2>&1; then
          echo "Certificate: not issued yet, leaving the BMC alone"
          exit 0
        fi
        desired="$(fingerprint <${certDir}/cert.pem)"
        current="$(served)"
        if [ "$current" = "$desired" ]; then
          echo "Certificate: $current"
          exit 0
        fi
        echo "Certificate: $current -> $desired"

        password="$(<${lib.escapeShellArg user.passwordFile})"
        printf '%s' "$password" >"$RUNTIME_DIRECTORY/password"
        : >"$RUNTIME_DIRECTORY/cookies"
        web() {
          curl --silent --show-error --fail --insecure \
            --cookie "$RUNTIME_DIRECTORY/cookies" --cookie-jar "$RUNTIME_DIRECTORY/cookies" \
            --header "Referer: https://${ipv4Address}/cgi/url_redirect.cgi?url_name=config_ssl" \
            ''${token:+--header "CSRF_TOKEN: $token"} "$@"
        }

        token=""
        web --data-urlencode "name=${user.name}" --data-urlencode "pwd@$RUNTIME_DIRECTORY/password" \
          https://${ipv4Address}/cgi/login.cgi >/dev/null
        if ! awk '$6 == "SID" && $7 != "" { found = 1 } END { exit !found }' "$RUNTIME_DIRECTORY/cookies"; then
          echo "Certificate: could not log in to the web UI" >&2
          exit 1
        fi
        trap 'web https://${ipv4Address}/cgi/logout.cgi >/dev/null || true; rm -f "$RUNTIME_DIRECTORY"/*' EXIT
        # Newer firmware wants the token the pages embed on every request
        token="$(web 'https://${ipv4Address}/cgi/url_redirect.cgi?url_name=topmenu' |
          sed -n 's/.*SmcCsrfInsert *( *"CSRF_TOKEN" *, *"\([^"]*\)".*/\1/p' | head -n 1)"

        # Some firmware only takes the leaf certificate, without the chain
        accepted=""
        for file in fullchain.pem cert.pem; do
          web --form "cert_file=@${certDir}/$file;type=application/octet-stream" \
            --form "key_file=@${certDir}/key.pem;type=application/octet-stream" \
            https://${ipv4Address}/cgi/upload_ssl.cgi >/dev/null
          validate="$(web --data-urlencode 'SSL_VALIDATE.XML=(0,0)' --data-urlencode "time_stamp=$(date -u)" \
            https://${ipv4Address}/cgi/ipmi.cgi)"
          if grep -q 'VALIDATE="1"' <<<"$validate"; then
            accepted="$file"
            break
          fi
          echo "Certificate: BMC rejected $file: $validate" >&2
        done
        if [ -z "$accepted" ]; then
          exit 1
        fi
        web https://${ipv4Address}/cgi/logout.cgi >/dev/null || true
        trap 'rm -f "$RUNTIME_DIRECTORY"/*' EXIT

        echo "Certificate: BMC took $accepted, resetting it"
        ipmilocked ipmitool mc reset cold
        for _ in $(seq 30); do
          sleep 10
          current="$(served)" || continue
          if [ "$current" = "$desired" ]; then
            echo "Certificate: BMC now serves $current"
            exit 0
          fi
        done
        echo "Certificate: BMC serves $current after its reset" >&2
        exit 1
      '';
    in
    lib.mkIf ipmiconfig.enable {
      assertions = [
        {
          assertion =
            !ipmiconfig.acme.enable || (user.passwordFile != null && netconfig.ipv4.address != null);
          message = "foxDen.ipmiconfig.acme needs user.passwordFile and network.ipv4.address";
        }
      ];

      foxDen.ipmiconfig = {
        network = lib.mkIf (netconfig.vlan != null) {
          ipv4.gateway = lib.mkDefault vlanConfig.ipv4.gateway;
          ipv6.address = lib.mkDefault (
            if netconfig.ipv4.address != null && vlanConfig.ipv6 != null then ipv6FromIpv4 else null
          );
          dns = lib.mkDefault vlanConfig.ipv4.dns;
          ntp = lib.mkDefault vlanConfig.ipv4.ntp;
        };
        user.passwordFile = config.lib.foxDen.sops.mkIfAvailable (
          lib.mkDefault config.sops.secrets.ipmiconfig-password.path
        );
      };

      sops.secrets.ipmiconfig-password = config.lib.foxDen.sops.mkIfAvailable { };
      sops.secrets.ipmiconfig-acme = lib.mkIf ipmiconfig.acme.enable (
        config.lib.foxDen.sops.mkIfAvailable { }
      );

      security.acme = lib.mkIf ipmiconfig.acme.enable (
        config.lib.foxDen.sops.mkIfAvailable {
          acceptTerms = true;
          certs.${fqdn} = {
            email = "ssl@foxden.network";
            # The BMC only takes RSA keys
            keyType = "rsa2048";
            dnsProvider = "hurricane";
            environmentFile = config.sops.secrets.ipmiconfig-acme.path;
            # Renew during the day, ahead of ipmiconfig-cert.timer
            renewInterval = "*-*-* 14:00:00";
            renewJitter = "30m";
          };
        }
      );
      # nixpkgs lets systemd move the renewal anywhere within the day
      systemd.timers."acme-renew-${fqdn}".timerConfig.AccuracySec = lib.mkIf certEnabled (
        lib.mkForce "1m"
      );

      foxDen.dns.records = lib.mkIf ipmiconfig.acme.enable [
        {
          fqdn = "_acme-challenge.${fqdn}";
          type = "TXT";
          value = "acme";
          ttl = 300; # dns.he.net's minimum
          dynDns = true;
          horizon = "external";
        }
      ];

      foxDen.hosts.hosts.${netconfig.hostName} = {
        launcher.webUI.url = lib.mkDefault "${
          if ipmiconfig.acme.enable then "https" else "http"
        }://${fqdn}/";
        interfaces.default = {
          driver.name = "null";
          useDHCP = false;
          dns = {
            fqdns = [ fqdn ];
          };
          addresses = lib.lists.filter (val: val != null) [
            netconfig.ipv4.address
            netconfig.ipv6.address
          ];
          mac = netconfig.mac;
        };
      };

      foxDen.firewall.rules = lib.mkIf (redfishEnabled || ipmiconfig.acme.enable) [
        {
          table = "filter";
          chain = "forward";
          action = "accept";
          source = {
            host = hostName;
          };
          destination = {
            host = netconfig.hostName;
          };
          dstport = 443;
          protocol = "tcp";
          comment = "ipmiconfig-${hostName}-allow-redfish";
        }
      ];

      boot.kernelModules = [ "ipmi_devintf" ];

      # Shared with superfan, which holds the same lock around its IPMI calls
      systemd.tmpfiles.settings.ipmi-lock."/run/lock/superfan".d = { };

      # Reruns on boot and whenever the script changes on a switch
      systemd.services.ipmiconfig = {
        description = "BMC network configuration";
        after = [
          "systemd-modules-load.service"
        ]
        ++ lib.optional redfishEnabled "network-online.target";
        wants = lib.optional redfishEnabled "network-online.target";
        path = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnused
          pkgs.ipmitool
          pkgs.jq
          pkgs.superfan
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "no";
          RuntimeDirectory = "ipmiconfig";
          UMask = "0077";
          ExecStart = [ configScript ];
        };
        wantedBy = [ "multi-user.target" ];
      };

      # The upload resets the BMC, which spins the fans up, so it runs from its
      # own afternoon timer instead of on every renewal. A missed run catches
      # up on boot, when the fans spin up anyway.
      systemd.timers.ipmiconfig-cert = lib.mkIf certEnabled {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 14:45:00";
          Persistent = true;
        };
      };
      systemd.services.ipmiconfig-cert = lib.mkIf certEnabled {
        description = "BMC web UI certificate";
        after = [
          "ipmiconfig.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
        path = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.ipmitool
          pkgs.openssl
          pkgs.superfan
        ];

        serviceConfig = {
          Type = "oneshot";
          Restart = "no";
          RuntimeDirectory = "ipmiconfig-cert";
          UMask = "0077";
          ExecStart = [ certScript ];
        };
      };
    };
}
