{ nixpkgs, foxDenLib, ... }:
let
  util = foxDenLib.util;
  eSA = lib.strings.escapeShellArg;
  lib = nixpkgs.lib;

  getByName = (
    config: name:
    let
      namespace = "host-${name}";
    in
    {
      inherit name;
      namespace = namespace;
      namespacePath = "/run/netns/${namespace}";
      unit = "netns-host-${name}.service";
      resolvConf = "/etc/foxden/hosts/${name}/resolv.conf";
    }
    // config.foxDen.hosts.hosts.${name}
  );
in
{
  getByName = getByName;

  nixosModule = (
    {
      config,
      pkgs,
      foxDenLib,
      ...
    }:
    let
      ptrMode = config.foxDen.hosts.ptrMode;

      portType =
        with lib.types;
        submodule {
          options = {
            port = lib.mkOption {
              type = nullOr ints.u16;
              default = null;
            };
            protocol = lib.mkOption {
              type = nullOr (enum [
                "tcp"
                "udp"
              ]);
              default = null;
            };
            source = lib.mkOption {
              type = nullOr str;
              default = null;
            };
            comment = lib.mkOption {
              type = str;
              default = "";
            };
          };
        };

      interfaceType =
        with lib.types;
        submodule {
          options = {
            driver = {
              name = lib.mkOption {
                type = enum (lib.attrsets.attrNames foxDenLib.hosts.drivers);
              };
            }
            // (lib.attrsets.genAttrs (lib.attrsets.attrNames foxDenLib.hosts.drivers) (
              name:
              lib.mkOption {
                type = foxDenLib.hosts.drivers.${name}.driverConfigType;
                default = foxDenLib.hosts.drivers.${name}.driverConfigDefault or { };
              }
            ));
            mac = lib.mkOption {
              type = nullOr str;
              default = null;
            };
            dhcpv6 = {
              duid = lib.mkOption {
                type = nullOr str;
                default = null;
              };
              iaid = lib.mkOption {
                type = nullOr ints.u32;
                default = null;
              };
            };
            webservice = {
              enable = lib.mkOption {
                type = bool;
                default = false;
              };
            };
            firewall = {
              ingressAcceptRules = lib.mkOption {
                type = listOf portType;
                default = [ ];
              };
              portForwards = lib.mkOption {
                type = listOf portType;
                default = [ ];
              };
            };
            dns = {
              fqdns = lib.mkOption {
                type = listOf str;
                default = [ ];
              };
              auxAddresses = lib.mkOption {
                type = uniq (listOf foxDenLib.types.ip);
                default = [ ];
              };
              ttl = lib.mkOption {
                type = ints.positive;
                default = 3600;
              };
              dynDns = lib.mkOption {
                type = bool;
                default = false;
              };
              critical = lib.mkOption {
                type = bool;
                default = false;
              };
              dynDnsTtl = lib.mkOption {
                type = nullOr ints.positive;
                default = 300;
              };
            };
            addresses = lib.mkOption {
              type = uniq (listOf foxDenLib.types.ip);
            };
            routes = lib.mkOption {
              type = nullOr (listOf routeType);
              default = [ ];
            };
            sysctls = lib.mkOption {
              type = attrsOf str;
              default = { };
            };
            useDHCP = lib.mkOption {
              type = bool;
              default = config.foxDen.hosts.useDHCP;
            };
            gateway = lib.mkOption {
              type = str;
              default = config.foxDen.hosts.gateway;
            };
          };
        };

      routeType =
        with lib.types;
        submodule {
          options = {
            Destination = lib.mkOption {
              type = nullOr foxDenLib.types.ip;
              default = null;
            };
            Gateway = lib.mkOption {
              type = nullOr foxDenLib.types.ipWithoutCidr;
              default = null;
            };
            GatewayOnLink = lib.mkOption {
              type = bool;
              default = false;
            };
          };
        };

      hostType =
        with lib.types;
        submodule {
          options = {
            interfaces = lib.mkOption {
              type = attrsOf interfaceType;
            };
            webservice = {
              enable = lib.mkOption {
                type = bool;
                default = false;
              };
              proxyProtocol = lib.mkOption {
                type = bool;
                default = true;
              };
              httpPort = lib.mkOption {
                type = ints.u16;
                default = 80;
              };
              httpsPort = lib.mkOption {
                type = ints.u16;
                default = 443;
              };
              httpProxyPort = lib.mkOption {
                type = ints.u16;
                default = 81;
              };
              httpsProxyPort = lib.mkOption {
                type = ints.u16;
                default = 444;
              };
              quicPort = lib.mkOption {
                type = ints.u16;
                default = 0;
              };
              readyUrl = lib.mkOption {
                type = str;
                default = "/readyz";
              };
              checkExpectCode = lib.mkOption {
                type = ints.positive;
                default = 200;
              };
            };
            ssh = lib.mkEnableOption "Does this host accept SSH connections";
            nameservers = lib.mkOption {
              type = listOf str;
              default = [ ];
            };
          };
        };

      hostIndexHex1 = lib.toHexString config.foxDen.hosts.index;
      hostIndexHex = if (lib.stringLength hostIndexHex1 == 1) then "0${hostIndexHex1}" else hostIndexHex1;

      mkHashMac = (
        hash:
        "e6:21:${hostIndexHex}:${builtins.substring 0 2 hash}:${builtins.substring 2 2 hash}:${builtins.substring 4 2 hash}"
      );

      hosts = map (getByName config) (lib.attrsets.attrNames config.foxDen.hosts.hosts);
      mapIfaces = (
        host:
        map (
          { name, value }:
          let
            hash = util.mkShortHash 6 (host.name + "|" + name);
          in
          value
          // {
            inherit host name;
            suffix = "${hostIndexHex}${hash}";
            mac = if value.mac != null then value.mac else (mkHashMac hash);
          }
        ) (lib.attrsets.attrsToList host.interfaces)
      );
      interfaces = lib.flatten (map mapIfaces hosts);

      ifaceHasV4 = (iface: lib.any util.isIPv4 iface.addresses);
      ifaceHasV6 = (iface: lib.any util.isIPv6 iface.addresses);

      ifaceFirstV4 = (iface: lib.findFirst util.isIPv4 "127.0.0.1" iface.addresses);
      ifaceFirstV6 = (iface: lib.findFirst util.isIPv6 "::1" iface.addresses);

      mkIfaceDynDnsOne = (
        iface: fqdn: check: type: value:
        if (check iface) then
          [
            {
              inherit fqdn type;
              ttl = iface.dns.dynDnsTtl;
              value = util.removeIPCidr (value iface);
              dynDns = true;
              horizon = "external";
            }
          ]
        else
          [ ]
      );

      mkIfaceDynDns = (
        iface: fqdn:
        if iface.dns.dynDns then
          (mkIfaceDynDnsOne iface fqdn ifaceHasV4 "A" ifaceFirstV4)
          ++ (mkIfaceDynDnsOne iface fqdn ifaceHasV6 "AAAA" ifaceFirstV6)
        else
          [ ]
      );

      networkSysctls = lib.attrsets.filterAttrs (
        n: v: (lib.strings.hasPrefix "net.ipv4." n) || (lib.strings.hasPrefix "net.ipv6." n)
      ) config.boot.kernel.sysctl;
    in
    {
      options.foxDen.hosts = with lib.types; {
        hosts = lib.mkOption {
          type = attrsOf hostType;
          default = { };
        };
        ptrMode = lib.mkOption {
          type = enum [
            "none"
            "internal"
            "external"
            "all"
          ];
          default = "internal";
        };
        defaultSysctls = lib.mkOption {
          type = attrsOf (
            nullOr (oneOf [
              str
              bool
              int
            ])
          );
          description = ''
            Default sysctl settings to apply to all interfaces.
          '';
        };
        gateway = lib.mkOption {
          type = str;
          default = "default";
        };
        useDHCP = lib.mkEnableOption "Configure DHCP lease for hosts on this system";
        usedMacAddresses = lib.mkOption {
          type = addCheck (listOf str) (
            macs:
            let
              uniqueMacs = lib.lists.uniqueString macs;
            in
            (lib.lists.length macs) == (lib.lists.length uniqueMacs)
          );
          description = ''
            List of MAC addresses that are already in use on your network.
            This is used to avoid generating colliding MAC addresses for interfaces.
          '';
        };
        index = lib.mkOption {
          type = ints.u8;
        };
      };

      config = {
        lib.foxDen.mkHashMac = mkHashMac;
        networking.useDHCP = config.foxDen.hosts.useDHCP;
        foxDen.hosts = {
          defaultSysctls = lib.attrsets.mapAttrs (n: v: lib.mkDefault v) (
            networkSysctls
            // {
              "net.ipv4.ip_unprivileged_port_start" = 1;
              "net.ipv6.conf.INTERFACE.accept_ra" = true;
            }
          );
          usedMacAddresses = map (iface: iface.mac) interfaces;
        };
        foxDen.dns.records = (
          lib.flatten (
            map (
              iface:
              let
                primaryFQDN = lib.lists.head iface.dns.fqdns;

                mkRecord = (
                  addr: {
                    inherit (iface.dns)
                      ttl
                      dynDns
                      critical
                      ;
                    fqdn = primaryFQDN;
                    type = if (util.isIPv6 addr) then "AAAA" else "A";
                    value = util.removeIPCidr addr;
                    horizon = if (util.isPrivateIP addr) then "internal" else "external";
                  }
                );
                mkPtr = (
                  addr:
                  let
                    horizon = if util.isPrivateIP addr then "internal" else "external";
                  in
                  lib.mkIf (ptrMode == "all" || ptrMode == horizon) {
                    inherit horizon;
                    inherit (iface.dns) ttl critical;
                    fqdn = util.mkPtr addr;
                    type = "PTR";
                    value = "${primaryFQDN}.";
                  }
                );
                mkIfaceAuxFQDNs = map (fqdn: {
                  inherit (iface.dns) ttl critical;
                  inherit fqdn;
                  type = "CNAME";
                  value = "${primaryFQDN}.";
                  horizon = "*";
                }) (lib.lists.tail iface.dns.fqdns);
              in
              (
                (map mkRecord (iface.addresses ++ iface.dns.auxAddresses))
                ++ (map mkPtr iface.addresses)
                ++ (mkIfaceDynDns iface primaryFQDN)
                ++ mkIfaceAuxFQDNs
              )
            ) (lib.lists.filter (iface: (lib.lists.length iface.dns.fqdns) > 0) interfaces)
          )
        );

        environment.etc = lib.listToAttrs (
          map (host: {
            name = lib.strings.removePrefix "/etc/" host.resolvConf;
            value.text = ''
              # Generated by foxDen
              ${lib.concatMapStrings (ns: "nameserver ${ns}\n") host.nameservers}
            '';
          }) hosts
        );

        systemd = lib.mkMerge (
          (map (
            { name, value }:
            (value.build {
              interfaces = (lib.filter (iface: iface.driver.name == name) interfaces);
            }).config.systemd
          ) (lib.attrsets.attrsToList foxDenLib.hosts.drivers))
          ++ [
            {
              # Configure each host's NetNS
              services = (
                lib.attrsets.listToAttrs (
                  map (
                    host:
                    let
                      ipCmd = eSA "${pkgs.iproute2}/bin/ip";
                      netnsExecCmd = "${ipCmd} netns exec ${eSA host.namespace}";
                      ipInNsCmd = "${netnsExecCmd} ${ipCmd}";

                      renderRoute = (
                        dev: route:
                        "${ipInNsCmd} route add "
                        + (if route.Destination != null then eSA route.Destination else "default")
                        + (if route.Gateway != null then " via ${eSA route.Gateway}" else " dev ${eSA dev}")
                        + (if route.GatewayOnLink == true then " onlink" else "")
                      );

                      mkHooks = (
                        interface:
                        let
                          ifaceDriver = foxDenLib.hosts.drivers.${interface.driver.name};

                          serviceInterface = "host${interface.suffix}";
                          driverRunParams = {
                            inherit
                              ipCmd
                              ipInNsCmd
                              netnsExecCmd
                              interface
                              pkgs
                              serviceInterface
                              ;
                          };
                          hooks = ifaceDriver.hooks driverRunParams;

                          sysctlsRaw = lib.filterAttrs (name: value: value != null) (
                            config.foxDen.hosts.defaultSysctls // interface.sysctls
                          );

                          settingToStr = setting: if setting == false then "0" else builtins.toString setting;

                          sysctls = lib.concatStringsSep "\n" (
                            map (
                              { name, value }: "${lib.replaceString "INTERFACE" serviceInterface name} = ${settingToStr value}"
                            ) (lib.attrsets.attrsToList sysctlsRaw)
                          );
                        in
                        {
                          start =
                            hooks.start
                            ++ [
                              "-${ipCmd} link set ${eSA serviceInterface} down"
                              "${ipCmd} link set ${eSA serviceInterface} netns ${eSA host.namespace}"
                            ]
                            ++ (map (addr: "${ipInNsCmd} addr add ${eSA addr} dev ${eSA serviceInterface}") interface.addresses)
                            ++ [
                              "${netnsExecCmd} ${pkgs.sysctl}/bin/sysctl -p ${pkgs.writers.writeText "sysctls" sysctls}"
                            ]
                            ++ (hooks.setMac or [
                              "${ipInNsCmd} link set ${eSA serviceInterface} address ${eSA interface.mac}"
                            ]
                            )
                            ++ [
                              "${ipInNsCmd} link set ${eSA serviceInterface} up"
                            ]
                            ++ (map (renderRoute serviceInterface) interface.routes);

                          stop = [ "${ipInNsCmd} link set ${eSA serviceInterface} down" ] ++ hooks.stop;
                        }
                      );
                    in
                    {
                      name = (lib.strings.removeSuffix ".service" host.unit);
                      value =
                        let
                          ifaceHooks = map mkHooks (lib.filter (iface: iface.host.name == host.name) interfaces);
                          getHook = sub: lib.flatten (map (cfg: cfg.${sub}) ifaceHooks);
                        in
                        {
                          description = "NetNS ${host.namespace}";
                          after = [ "network-pre.target" ];
                          restartTriggers = [ (builtins.concatStringsSep " " host.nameservers) ];

                          serviceConfig = {
                            Type = "oneshot";
                            RemainAfterExit = true;

                            ExecStart = [
                              "-${ipCmd} netns del ${eSA host.namespace}"
                              "${ipCmd} netns add ${eSA host.namespace}"
                              "${ipInNsCmd} addr add 127.0.0.1/8 dev lo"
                              "${ipInNsCmd} addr add ::1/128 dev lo noprefixroute"
                              "${ipInNsCmd} link set lo up"
                            ]
                            ++ (getHook "start");

                            ExecStop = getHook "stop";
                            ExecStopPost = [ "${ipCmd} netns del ${eSA host.namespace}" ];

                            TimeoutStartSec = "5min";
                          };
                        };
                    }
                  ) hosts
                )
              );
            }
          ]
        );
      };
    }
  );
}
