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

      redfishEnabled =
        user.passwordFile != null
        && netconfig.ipv4.address != null
        && (netconfig.dns != [ ] || netconfig.ntp != [ ]);

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
              echo "$name: not supported by the BMC, not touching it" >&2
              failed=1
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
            redfishensure "NTP" /redfish/v1/Managers/1/NetworkProtocol \
              '.NTP | if . == null then null else {ProtocolEnabled, NTPServers: ((.NTPServers // []) | map(select(. != "")))} end' \
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
          ''}

          ${lib.optionalString (netconfig.dns != [ ]) ''
            redfishensure "DNS" /redfish/v1/Managers/1/EthernetInterfaces/1 \
              '.StaticNameServers | if . == null then null else map(select(. != "" and . != "0.0.0.0")) end' \
              ${lib.escapeShellArg (builtins.toJSON netconfig.dns)} \
              ${lib.escapeShellArg (builtins.toJSON { StaticNameServers = netconfig.dns; })}
          ''}
        ''}

        exit $failed
      '';
    in
    lib.mkIf ipmiconfig.enable {
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

      foxDen.hosts.hosts.${netconfig.hostName} = {
        launcher.webUI.url = lib.mkDefault "http://${netconfig.hostName}.${netconfig.hostZone}/";
        interfaces.default = {
          driver.name = "null";
          useDHCP = false;
          dns = {
            fqdns = [ "${netconfig.hostName}.${netconfig.hostZone}" ];
          };
          addresses = lib.lists.filter (val: val != null) [
            netconfig.ipv4.address
            netconfig.ipv6.address
          ];
          mac = netconfig.mac;
        };
      };

      foxDen.firewall.rules = lib.mkIf redfishEnabled [
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
    };
}
