{ nixpkgs, foxDenLib, ... }:
let
  util = foxDenLib.util;
  eSA = nixpkgs.lib.strings.escapeShellArg;

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
      cnameType =
        with nixpkgs.lib.types;
        submodule {
          options = {
            name = nixpkgs.lib.mkOption {
              type = str;
            };
            zone = nixpkgs.lib.mkOption {
              type = str;
            };
            type = nixpkgs.lib.mkOption {
              type = enum [
                "CNAME"
                "ALIAS"
              ];
              default = "CNAME";
            };
          };
        };

      portType =
        with nixpkgs.lib.types;
        submodule {
          options = {
            port = nixpkgs.lib.mkOption {
              type = nullOr ints.u16;
              default = null;
            };
            protocol = nixpkgs.lib.mkOption {
              type = nullOr (enum [
                "tcp"
                "udp"
              ]);
              default = null;
            };
            source = nixpkgs.lib.mkOption {
              type = nullOr str;
              default = null;
            };
            comment = nixpkgs.lib.mkOption {
              type = str;
              default = "";
            };
          };
        };

      interfaceType =
        with nixpkgs.lib.types;
        submodule {
          options = {
            driver = {
              name = nixpkgs.lib.mkOption {
                type = enum (nixpkgs.lib.attrsets.attrNames foxDenLib.hosts.drivers);
              };
            }
            // (nixpkgs.lib.attrsets.genAttrs (nixpkgs.lib.attrsets.attrNames foxDenLib.hosts.drivers) (
              name:
              nixpkgs.lib.mkOption {
                type = foxDenLib.hosts.drivers.${name}.driverConfigType;
                default = foxDenLib.hosts.drivers.${name}.driverConfigDefault or { };
              }
            ));
            mac = nixpkgs.lib.mkOption {
              type = nullOr str;
              default = null;
            };
            dhcpv6 = {
              duid = nixpkgs.lib.mkOption {
                type = nullOr str;
                default = null;
              };
              iaid = nixpkgs.lib.mkOption {
                type = nullOr ints.u32;
                default = null;
              };
            };
            webservice = {
              enable = nixpkgs.lib.mkOption {
                type = bool;
                default = false;
              };
            };
            firewall = {
              ingressAcceptRules = nixpkgs.lib.mkOption {
                type = listOf portType;
                default = [ ];
              };
              portForwards = nixpkgs.lib.mkOption {
                type = listOf portType;
                default = [ ];
              };
            };
            dns = {
              name = nixpkgs.lib.mkOption {
                type = str;
                default = "";
              };
              auxAddresses = nixpkgs.lib.mkOption {
                type = uniq (listOf foxDenLib.types.ip);
                default = [ ];
              };
              ttl = nixpkgs.lib.mkOption {
                type = ints.positive;
                default = 3600;
              };
              dynDns = nixpkgs.lib.mkOption {
                type = bool;
                default = false;
              };
              critical = nixpkgs.lib.mkOption {
                type = bool;
                default = false;
              };
              dynDnsTtl = nixpkgs.lib.mkOption {
                type = nullOr ints.positive;
                default = 300;
              };
            };
            cnames = nixpkgs.lib.mkOption {
              type = listOf cnameType;
              default = [ ];
            };
            addresses = nixpkgs.lib.mkOption {
              type = uniq (listOf foxDenLib.types.ip);
            };
            routes = nixpkgs.lib.mkOption {
              type = nullOr (listOf routeType);
              default = [ ];
            };
            sysctls = nixpkgs.lib.mkOption {
              type = attrsOf str;
              default = { };
            };
            useDHCP = nixpkgs.lib.mkOption {
              type = bool;
              default = config.foxDen.hosts.useDHCP;
            };
            gateway = nixpkgs.lib.mkOption {
              type = str;
              default = config.foxDen.hosts.gateway;
            };
          };
        };

      routeType =
        with nixpkgs.lib.types;
        submodule {
          options = {
            Destination = nixpkgs.lib.mkOption {
              type = nullOr foxDenLib.types.ip;
              default = null;
            };
            Gateway = nixpkgs.lib.mkOption {
              type = nullOr foxDenLib.types.ipWithoutCidr;
              default = null;
            };
          };
        };

      hostType =
        with nixpkgs.lib.types;
        submodule {
          options = {
            interfaces = nixpkgs.lib.mkOption {
              type = attrsOf interfaceType;
            };
            webservice = {
              enable = nixpkgs.lib.mkOption {
                type = bool;
                default = false;
              };
              proxyProtocol = nixpkgs.lib.mkOption {
                type = bool;
                default = true;
              };
              httpPort = nixpkgs.lib.mkOption {
                type = ints.u16;
                default = 80;
              };
              httpsPort = nixpkgs.lib.mkOption {
                type = ints.u16;
                default = 443;
              };
              httpProxyPort = nixpkgs.lib.mkOption {
                type = ints.u16;
                default = 81;
              };
              httpsProxyPort = nixpkgs.lib.mkOption {
                type = ints.u16;
                default = 444;
              };
              quicPort = nixpkgs.lib.mkOption {
                type = ints.u16;
                default = 0;
              };
              readyUrl = nixpkgs.lib.mkOption {
                type = str;
                default = "/readyz";
              };
              checkExpectCode = nixpkgs.lib.mkOption {
                type = ints.positive;
                default = 200;
              };
            };
            ssh = nixpkgs.lib.mkEnableOption "Does this host accept SSH connections";
            nameservers = nixpkgs.lib.mkOption {
              type = listOf str;
              default = [ ];
            };
          };
        };

      hostIndexHex1 = nixpkgs.lib.toHexString config.foxDen.hosts.index;
      hostIndexHex =
        if (nixpkgs.lib.stringLength hostIndexHex1 == 1) then "0${hostIndexHex1}" else hostIndexHex1;

      mkHashMac = (
        hash:
        "e6:21:${hostIndexHex}:${builtins.substring 0 2 hash}:${builtins.substring 2 2 hash}:${builtins.substring 4 2 hash}"
      );

      hosts = map (getByName config) (nixpkgs.lib.attrsets.attrNames config.foxDen.hosts.hosts);
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
        ) (nixpkgs.lib.attrsets.attrsToList host.interfaces)
      );
      interfaces = nixpkgs.lib.flatten (map mapIfaces hosts);

      ifaceHasV4 = (iface: nixpkgs.lib.any util.isIPv4 iface.addresses);
      ifaceHasV6 = (iface: nixpkgs.lib.any util.isIPv6 iface.addresses);

      ifaceFirstV4 = (iface: nixpkgs.lib.findFirst util.isIPv4 "127.0.0.1" iface.addresses);
      ifaceFirstV6 = (iface: nixpkgs.lib.findFirst util.isIPv6 "::1" iface.addresses);

      mkIfaceDynDnsOne = (
        iface: check: type: value:
        if (check iface) then
          [
            {
              name = iface.dns.name;
              type = type;
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
        iface:
        if iface.dns.dynDns then
          (mkIfaceDynDnsOne iface ifaceHasV4 "A" ifaceFirstV4)
          ++ (mkIfaceDynDnsOne iface ifaceHasV6 "AAAA" ifaceFirstV6)
        else
          [ ]
      );

      networkSysctls = nixpkgs.lib.attrsets.filterAttrs (
        n: v: (nixpkgs.lib.strings.hasPrefix "net.ipv4." n) || (nixpkgs.lib.strings.hasPrefix "net.ipv6." n)
      ) config.boot.kernel.sysctl;
    in
    {
      options.foxDen.hosts = with nixpkgs.lib.types; {
        hosts = nixpkgs.lib.mkOption {
          type = attrsOf hostType;
          default = { };
        };
        defaultSysctls = nixpkgs.lib.mkOption {
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
        gateway = nixpkgs.lib.mkOption {
          type = str;
          default = "default";
        };
        useDHCP = nixpkgs.lib.mkEnableOption "Configure DHCP lease for hosts on this system";
        usedMacAddresses = nixpkgs.lib.mkOption {
          type = addCheck (listOf str) (
            macs:
            let
              uniqueMacs = nixpkgs.lib.lists.uniqueString macs;
            in
            (nixpkgs.lib.lists.length macs) == (nixpkgs.lib.lists.length uniqueMacs)
          );
          description = ''
            List of MAC addresses that are already in use on your network.
            This is used to avoid generating colliding MAC addresses for interfaces.
          '';
        };
        index = nixpkgs.lib.mkOption {
          type = ints.u8;
        };
      };

      config = {
        lib.foxDen.mkHashMac = mkHashMac;
        networking.useDHCP = config.foxDen.hosts.useDHCP;
        foxDen.hosts = {
          defaultSysctls = nixpkgs.lib.attrsets.mapAttrs (n: v: nixpkgs.lib.mkDefault v) (
            networkSysctls
            // {
              "net.ipv4.ip_unprivileged_port_start" = 1;
              "net.ipv6.conf.INTERFACE.accept_ra" = true;
            }
          );
          usedMacAddresses = map (iface: iface.mac) interfaces;
        };
        foxDen.dns.records = (
          nixpkgs.lib.flatten (
            map (
              iface:
              let
                mkRecord = (
                  addr:
                  nixpkgs.lib.mkIf (iface.dns.name != "") {
                    inherit (iface.dns)
                      name
                      ttl
                      dynDns
                      critical
                      ;
                    type = if (util.isIPv6 addr) then "AAAA" else "A";
                    value = util.removeIPCidr addr;
                    horizon = if (util.isPrivateIP addr) then "internal" else "external";
                  }
                );
                mkPtr = (
                  addr:
                  let
                    revName = util.mkPtr addr;
                  in
                  nixpkgs.lib.mkIf (iface.dns.name != "") {
                    inherit (iface.dns) ttl critical;
                    name = revName;
                    type = "PTR";
                    value = "${foxDenLib.global.dns.mkHost iface.dns}.";
                    horizon = if (util.isPrivateIP addr) then "internal" else "external";
                  }
                );
                ifaceCnames = map (cname: {
                  inherit (iface.dns) ttl critical;
                  inherit (cname) name type;
                  value = "${foxDenLib.global.dns.mkHost iface.dns}.";
                  horizon = "*";
                }) iface.cnames;
              in
              (
                (map mkRecord (iface.addresses ++ iface.dns.auxAddresses))
                ++ (map mkPtr iface.addresses)
                ++ (mkIfaceDynDns iface)
                ++ ifaceCnames
              )
            ) interfaces
          )
        );

        environment.etc = nixpkgs.lib.listToAttrs (
          map (host: {
            name = nixpkgs.lib.strings.removePrefix "/etc/" host.resolvConf;
            value.text = ''
              # Generated by foxDen
              ${nixpkgs.lib.concatMapStrings (ns: "nameserver ${ns}\n") host.nameservers}
            '';
          }) hosts
        );

        systemd = nixpkgs.lib.mkMerge (
          (map (
            { name, value }:
            (value.build {
              interfaces = (nixpkgs.lib.filter (iface: iface.driver.name == name) interfaces);
            }).config.systemd
          ) (nixpkgs.lib.attrsets.attrsToList foxDenLib.hosts.drivers))
          ++ [
            {
              # Configure each host's NetNS
              services = (
                nixpkgs.lib.attrsets.listToAttrs (
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

                          sysctlsRaw = nixpkgs.lib.filterAttrs (name: value: value != null) (
                            config.foxDen.hosts.defaultSysctls // interface.sysctls
                          );

                          settingToStr = setting: if setting == false then "0" else builtins.toString setting;

                          sysctls = nixpkgs.lib.concatStringsSep "\n" (
                            map (
                              { name, value }:
                              "${nixpkgs.lib.replaceString "INTERFACE" serviceInterface name} = ${settingToStr value}"
                            ) (nixpkgs.lib.attrsets.attrsToList sysctlsRaw)
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
                      name = (nixpkgs.lib.strings.removeSuffix ".service" host.unit);
                      value =
                        let
                          ifaceHooks = map mkHooks (nixpkgs.lib.filter (iface: iface.host.name == host.name) interfaces);
                          getHook = sub: nixpkgs.lib.flatten (map (cfg: cfg.${sub}) ifaceHooks);
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
