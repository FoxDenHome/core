{ nixpkgs, foxDenLib, ... }:
let
  lib = nixpkgs.lib;
  util = foxDenLib.util;
  globalConfig = foxDenLib.global.config;

  mkForGateway =
    gateway: allHosts:
    let
      hosts = lib.lists.filter (val: val.gateway == gateway) allHosts;

      renderMatchers = (
        cfgName: varName:
        nixpkgs.lib.concatStringsSep "\n" (
          nixpkgs.lib.flatten (
            map (
              host:
              let
                name = "${cfgName}_${nixpkgs.lib.lists.head host.names}";
              in
              if host.host != null then
                (map (hostName: "  acl acl_${name} ${varName} -i ${hostName}") host.names)
                ++ [
                  "  use_backend be_${name} if acl_${name}"
                ]
              else
                [ ]
            ) hosts
          )
        )
      );

      renderBackends = (
        cfgName: mode: directives: addFlags:
        nixpkgs.lib.concatStringsSep "\n" (
          map (
            host:
            let
              primaryHost = nixpkgs.lib.lists.head host.names;
              procHostVars = vals: map (val: nixpkgs.lib.replaceString "__HOST__" primaryHost val) vals;
              name = "${cfgName}_${primaryHost}";
              flags = [
                "check"
              ]
              ++ (procHostVars addFlags)
              ++ (if host.proxyProtocol then [ "send-proxy-v2" ] else [ ]);
            in
            if host.host != null then
              ''
                backend be_${name}
                  mode ${mode}
                  option httpchk
                  http-check send meth GET uri ${host.readyUrl} hdr Host ${primaryHost}
                  http-check expect status ${builtins.toString host.checkExpectCode}
                ${
                  if directives != [ ] then
                    nixpkgs.lib.concatStringsSep "\n" (map (dir: "  ${dir}") (procHostVars directives))
                  else
                    ""
                }
                  server srv_main ${host.host}:${
                    builtins.toString host."${cfgName}Port"
                  } ${nixpkgs.lib.concatStringsSep " " flags}
              ''
            else
              ""
          ) hosts
        )
      );
    in
    ''
      global
        #uid# 980
        #gid# 980
        log stdout format raw local0 warning

      defaults
        log global
        timeout client 30s
        timeout server 30s
        timeout connect 5s
        option dontlognull
        option httpchk
        http-check expect status 200

      frontend fe_stats
        mode http
        bind :9001
        stats uri /stats
        stats enable
        stats refresh 10s
        stats show-modules
        http-request use-service prometheus-exporter if { path /metrics }

      frontend fe_https
        bind :443
        mode tcp
        tcp-request inspect-delay 5s
        tcp-request content accept if { req_ssl_hello_type 1 }
      ${renderMatchers "https" "req.ssl_sni"}

      frontend fe_http
        bind :80
        mode http
      ${renderMatchers "http" "hdr(host)"}

      ${renderBackends "http" "http"
        [
          "option forwardfor"
        ]
        [ ]
      }

      ${renderBackends "https" "tcp"
        [ ]
        [
          "ca-file /etc/ssl/certs/ca-certificates.crt"
          "check-ssl"
          "check-sni __HOST__"
        ]
      }
    '';
in
{
  nixosModule =
    { config, ... }:
    let
      hostType =
        with lib.types;
        submodule {
          options = {
            names = lib.mkOption {
              type = listOf str;
            };
            host = lib.mkOption {
              type = nullOr str;
              default = null;
            };
            httpPort = lib.mkOption {
              type = ints.u16;
              default = 80;
            };
            httpsPort = lib.mkOption {
              type = ints.u16;
              default = 443;
            };
            readyUrl = lib.mkOption {
              type = str;
              default = "/readyz";
            };
            checkExpectCode = nixpkgs.lib.mkOption {
              type = ints.positive;
              default = 200;
            };
            proxyProtocol = lib.mkOption {
              type = bool;
              default = true;
            };
            gateway = lib.mkOption {
              type = str;
              default = config.foxDen.hosts.gateway;
            };
          };
        };

      renderInterface = (
        hostName: ifaceObj: hostVal:
        let
          iface = ifaceObj.value;
          privateIPv4 = lib.findFirst (
            ip:
            let
              ipNoCidr = util.removeIPCidr ip;
            in
            (util.isIPv4 ipNoCidr) && (util.isPrivateIP ipNoCidr)
          ) "" iface.addresses;
        in
        lib.mkIf (privateIPv4 != "" && iface.webservice.enable) {
          inherit (iface) gateway;
          inherit (hostVal.webservice) readyUrl checkExpectCode proxyProtocol;
          names = map (record: record.fqdn) ([ iface.dns ] ++ iface.cnames);
          host = util.removeIPCidr privateIPv4;
          httpPort =
            if hostVal.webservice.proxyProtocol then
              hostVal.webservice.httpProxyPort
            else
              hostVal.webservice.httpPort;
          httpsPort =
            if hostVal.webservice.proxyProtocol then
              hostVal.webservice.httpsProxyPort
            else
              hostVal.webservice.httpsPort;
        }
      );

      renderHost =
        { name, value }:
        map (iface: renderInterface name iface value) (lib.attrsets.attrsToList value.interfaces);
    in
    {
      options.foxDen.haproxy.hosts =
        with lib.types;
        lib.mkOption {
          type = listOf hostType;
          default = { };
        };
      config.foxDen.haproxy.hosts = lib.flatten (
        map renderHost (nixpkgs.lib.attrsets.attrsToList config.foxDen.hosts.hosts)
      );
    };

  make =
    nixosConfigurations:
    let
      hosts = globalConfig.getList [ "foxDen" "haproxy" "hosts" ] nixosConfigurations;
      gateways = foxDenLib.global.hosts.getGateways nixosConfigurations;
    in
    lib.attrsets.genAttrs gateways (gateway: mkForGateway gateway hosts);
}
