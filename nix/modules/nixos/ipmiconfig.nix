{ lib, pkgs, foxDenLib, config, hostName, ... }:
let
  netConfigFamily = ipWithCidr: ipWithoutCidr: with lib.types; submodule {
    options = {
      address = lib.mkOption {
        type = nullOr ipWithCidr;
        default = null;
      };
      gateway = lib.mkOption {
        type = nullOr ipWithoutCidr;
        default = null;
      };
      dns = lib.mkOption {
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
        type = enum [ "shared" "dedicated" "failover" ];
        default = "dedicated";
      };
      mac = lib.mkOption {
        type = str;
      };
      ipv4 = lib.mkOption {
        type = netConfigFamily foxDenLib.types.ipv4WithCidr foxDenLib.types.ipv4WithoutCidr;
        default = {};
      };
      ipv6 = lib.mkOption {
        type = netConfigFamily foxDenLib.types.ipv6WithCidr foxDenLib.types.ipv6WithoutCidr;
        default = {};
      };
    };
    extraScript = lib.mkOption {
      type = str;
      default = "";
    };
  };

  config = let
    ipmiconfig = config.foxDen.ipmiconfig;
    netconfig = ipmiconfig.network;

    rawInterfaceModeMap = {
      dedicated = "0";
      shared = "1";
      failover = "2";
    };

    configScript = ''
      set -x
      echo 'FIXME: Disabled for now'
      exit 0

      ipmitool lan set 1 ipsrc static
      ipmitool lan set 1 ipaddr ${foxDenLib.util.removeIPCidr netconfig.ipv4.address}
      ipmitool lan set 1 netmask ${foxDenLib.util.ipv4Netmask netconfig.ipv4.address}
      ipmitool lan set 1 defgw ipaddr ${netconfig.ipv4.gateway}

      ipmitool lan6 set 1 nolock enables both
      ipmitool lan6 set 1 nolock static_addr 0 enable ${lib.replaceString "/" " " netconfig.ipv6.address}
      ipmitool lan6 set 1 nolock rtr_cfg dynamic

      # Raw code to set interface to "${netconfig.interface}" mode
      ipmitool raw 0x30 0x70 0x0c 1 ${rawInterfaceModeMap.${netconfig.interface}}

      ipmitool dcmi set_mc_id_string "${netconfig.hostName}"

      # BEGIN EXTRA CONFIG #
      ${ipmiconfig.extraScript}
      # END EXTRA CONFIG #
    '';
  in lib.mkIf ipmiconfig.enable {
    foxDen.hosts.hosts.${netconfig.hostName} = {
      interfaces.default = {
        driver.name = "null";
        useDHCP = false;
        dns = {
          name = "${netconfig.hostName}.${netconfig.hostZone}";
        };
        addresses = lib.lists.filter (val: val != null) [
          netconfig.ipv4.address
          netconfig.ipv6.address
        ];
        mac = netconfig.mac;
      };
    };

    systemd.services.ipmiconfig = {
      path = [
        pkgs.ipmitool
        pkgs.systemd
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "no";
        ExecStart = [
          "${pkgs.superfan}/bin/ipmilocked ${pkgs.writeShellScript "ipmiconfig.sh" configScript}"
        ];
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}