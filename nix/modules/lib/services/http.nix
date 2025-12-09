{ nixpkgs, foxDenLib, ... }:
let
  services = foxDenLib.services;
  eSA = nixpkgs.lib.strings.escapeShellArg;

  mkOauthConfig = (
    {
      config,
      svcConfig,
      oAuthCallbackUrl ? "/oauth2/callback",
      ...
    }:
    let
      host = foxDenLib.hosts.getByName config svcConfig.host;
      baseUrlPrefix = if svcConfig.tls then "https://" else "http://";
      baseUrls = nixpkgs.lib.lists.uniqueStrings (
        nixpkgs.lib.flatten (
          map (iface: (map (dns: "${baseUrlPrefix}${dns}") iface.dns.fqdns)) (
            nixpkgs.lib.attrsets.attrValues host.interfaces
          )
        )
      );

      imageFileObj =
        if svcConfig.oAuth.imageFile != null then
          {
            # Interpolation is the only good way to resolve the path here
            # builtins.toString does not create the /nix/store copy
            # thus causing a re-deploy for every single git push
            imageFile = "${svcConfig.oAuth.imageFile}";
          }
        else
          { };
    in
    {
      present = true;
      public = true;
      displayName = svcConfig.oAuth.displayName;
      originUrl = map (url: "${url}${oAuthCallbackUrl}") baseUrls;
      originLanding = nixpkgs.lib.lists.head baseUrls;
      scopeMaps.login-users = [
        "preferred_username"
        "email"
        "openid"
        "profile"
      ];
    }
    // imageFileObj
  );

  mkOauthProxy = (
    inputs@{
      config,
      svcConfig,
      pkgs,
      ...
    }:
    let
      name = inputs.name;
      serviceName = "oauth2-proxy-${name}";

      svc = services.mkNamed serviceName inputs;
      cmd = (eSA "${pkgs.oauth2-proxy}/bin/oauth2-proxy");
      secure = if svcConfig.tls then "true" else "false";

      configFile = "${svc.configDir}/${name}.conf";
      configFileEtc = nixpkgs.lib.strings.removePrefix "/etc/" configFile;

      cookieSecretFile = "/run/${serviceName}/cookie-secret";
    in
    {
      config = (
        nixpkgs.lib.mkMerge [
          svc.config
          {
            environment.etc.${configFileEtc} = {
              text = ''
                http_address = "127.0.0.1:4180"
                reverse_proxy = true
                provider = "oidc"
                provider_display_name = "FoxDen"
                code_challenge_method = "S256"
                email_domains = ["*"]
                scope = "openid email profile"
                cookie_name = "_oauth2_proxy"
                cookie_expire = "168h"
                cookie_httponly = true
                cookie_secure = ${secure}
                skip_provider_button = true
                set_xauthrequest = true

                client_id = "${svcConfig.oAuth.clientId}"
                client_secret = "PKCE"
                cookie_secret_file = "${cookieSecretFile}"
                oidc_issuer_url = "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}"
              '';
              user = "root";
              group = "root";
              mode = "0600";
            };

            foxDen.services.kanidm.oauth2.${svcConfig.oAuth.clientId} = mkOauthConfig inputs;

            systemd.services.${serviceName} = {
              restartTriggers = [ config.environment.etc.${configFileEtc}.text ];
              serviceConfig = {
                DynamicUser = true;
                ExecStartPre = [
                  (pkgs.writeShellScript "generate-cookie-secret" ''
                    if [ ! -f ${cookieSecretFile} ]; then
                      ${pkgs.coreutils}/bin/dd if=/dev/urandom bs=16 count=1 | ${pkgs.coreutils}/bin/base64 -w 0 > ${cookieSecretFile}
                    fi
                    ${pkgs.coreutils}/bin/chmod 600 ${cookieSecretFile}
                  '')
                ];
                RuntimeDirectory = serviceName;
                RuntimeDirectoryMode = "0700";
                LoadCredential = "oauth2-proxy.conf:${configFile}";
                ExecStart = "${cmd} --config=\"\${CREDENTIALS_DIRECTORY}/oauth2-proxy.conf\"";
              };
              wantedBy = [ "multi-user.target" ];
            };
          }
        ]
      );
    }
  );

  mkNginxHandler = (
    pkgs: handler: svcConfig:
    if (svcConfig.oAuth.enable && (!svcConfig.oAuth.overrideService)) then
      ''
        location /oauth2/ {
          proxy_pass http://127.0.0.1:4180;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Auth-Request-Redirect $request_uri;
        }
        location = /oauth2/auth {
          proxy_pass http://127.0.0.1:4180;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-Uri $request_uri;
          # nginx auth_request includes headers but not body
          proxy_set_header Content-Length "";
          proxy_pass_request_body off;
        }

        location / {
          ${
            if svcConfig.oAuth.bypassTrusted then
              ''
                satisfy any;
                allow 10.1.0.0/16;
                allow 10.2.0.0/16;
                allow fd2c:f4cb:63be:1::/64;
                allow fd2c:f4cb:63be:2::/64;
                deny all;
              ''
            else
              ""
          }
          auth_request /oauth2/auth;
          ${pkgs.foxden-http-errors.passthru.nginxErrorPages (
            nixpkgs.lib.filter (code: code != "401") (
              nixpkgs.lib.attrNames pkgs.foxden-http-errors.passthru.httpStateMap
            )
          )}
          error_page 401 =307 /oauth2/sign_in;

          auth_request_set $user $upstream_http_x_auth_request_user;
          auth_request_set $email $upstream_http_x_auth_request_email;
          proxy_set_header X-User $user;
          proxy_set_header X-Email $email;
          ${handler}
        }
      ''
    else
      ''
        location / {
          ${handler}
        }
      ''
  );
in
{
  nixosModule =
    { ... }:
    {
      options.foxDen.services.trustedProxies =
        with nixpkgs.lib.types;
        nixpkgs.lib.mkOption {
          type = listOf foxDenLib.types.ip;
          default = [ ];
        };

      config.foxDen.services.trustedProxies = [
        "10.1.0.0/23"
        "10.2.0.0/23"
        "10.3.0.0/23"
        "10.4.0.0/23"
        "10.5.0.0/23"
        "10.6.0.0/23"
        "10.7.0.0/23"
        "10.8.0.0/23"
        "10.9.0.0/23"
      ];
    };

  inherit mkOauthConfig;

  mkOptions = (
    inputs@{ ... }:
    with nixpkgs.lib.types;
    {
      tls = nixpkgs.lib.mkEnableOption "TLS";
      customReadyz = nixpkgs.lib.mkEnableOption "Don't handle /readyz endpoint for custom health checks";
      quic = nixpkgs.lib.mkEnableOption "Enable QUIC (HTTP/3) support";
      anubis = {
        enable = nixpkgs.lib.mkEnableOption "Enable Anubis integration for bot protection";
        default = nixpkgs.lib.mkEnableOption "Enable Anubis by default on all routes";
      };
      oAuth = {
        enable = nixpkgs.lib.mkEnableOption "OAuth2 support";
        bypassTrusted = nixpkgs.lib.mkEnableOption "Bypass OAuth for trusted VLAN requests";
        overrideService = nixpkgs.lib.mkEnableOption "Don't setup OAuth2 Proxy service, the service has special handling";
        clientId = nixpkgs.lib.mkOption {
          type = str;
        };
        displayName = nixpkgs.lib.mkOption {
          type = str;
        };
        imageFile = nixpkgs.lib.mkOption {
          type = nullOr (either path str);
          default = null;
        };
      };
    }
    // (services.mkOptions inputs)
  );

  make = (
    inputs@{
      config,
      svcConfig,
      pkgs,
      dynamicUser ? true,
      modules ? [ ],
      rawConfig ? null,
      ...
    }:
    let
      name = inputs.name;

      package = (if svcConfig.quic then pkgs.nginxQuic else pkgs.nginx).override {
        modules = nixpkgs.lib.lists.unique (
          [
            pkgs.nginxModules.njs
          ]
          ++ modules
        );
      };

      storageRoot = "/var/lib/foxden/${name}";

      host = foxDenLib.hosts.getByName config svcConfig.host;

      hostMatchers = nixpkgs.lib.lists.uniqueStrings (
        nixpkgs.lib.flatten (map (iface: iface.dns.fqdns) (nixpkgs.lib.attrsets.attrValues host.interfaces))
      );

      svc = services.mkNamed name inputs;
      confFilePath = "${svc.configDir}/nginx.conf";
      confFileEtc = nixpkgs.lib.strings.removePrefix "/etc/" confFilePath;

      readyzConf =
        enabled:
        if enabled then
          ''
            location = /readyz {
              add_header Content-Type text/plain always;
              return 200 "OK";
            }
          ''
        else
          ''
            # Normal /readyz handling disabled
          '';

      anubisConfig = ''
        proxy_pass http://unix:/run/anubis/anubis-${name}/anubis.sock;

        proxy_set_header X-Real-Ip $remote_addr;
        proxy_set_header Host $host;
        proxy_set_header X-Http-Version $server_protocol;
      '';

      configFuncData = {
        inherit
          anubisConfig
          baseWebConfig
          defaultTarget
          package
          proxyConfig
          proxyConfigNoHost
          ;
      };

      anubisListener =
        flags:
        if svcConfig.anubis.enable then
          "listen unix:/run/anubis/anubis-${name}/nginx.sock ${flags};"
        else
          "";

      proxyConfigNoHost = ''
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;
        fastcgi_request_buffering off;
        fastcgi_buffering off;
        client_max_body_size 0;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        include ${package}/conf/fastcgi_params;
      '';
      proxyConfig = ''
        ${proxyConfigNoHost}
        proxy_set_header Host $host;
      '';
      defaultTarget = ''
        ${proxyConfig}
        ${inputs.target}
      '';
      hostConfig = ''
        # Custom config can be injected here
        ${if inputs.extraConfig or "" != "" then inputs.extraConfig configFuncData else ""}
        # Auto generated config below
        ${mkNginxHandler pkgs defaultTarget svcConfig}
      '';
      baseHttpConfig = readyz: ''
        listen 80;
        listen [::]:80;
        listen 81;
        listen [::]:81;

        location @acmePeriodicAuto {
          js_periodic acme.clientAutoMode interval=1m;
        }

        location /.well-known/acme-challenge/ {
          js_content acme.challengeResponse;
        }

        location /.within.website/ {
          ${anubisConfig}
        }

        include ${pkgs.foxden-http-errors.passthru.nginxConf};

        ${readyzConf readyz}
      '';
      baseHttpsConfig = readyz: ''
        listen 443;
        listen [::]:443;
        ${
          if svcConfig.quic then
            ''
              listen 443 quic;
              listen [::]:443 quic;
            ''
          else
            ""
        }
        listen 444;
        listen [::]:444;
        http2 on;


        js_set $dynamic_ssl_cert acme.js_cert;
        js_set $dynamic_ssl_key acme.js_key;
        ssl_certificate data:$dynamic_ssl_cert;
        ssl_certificate_key data:$dynamic_ssl_key;

        location /.well-known/acme-challenge/ {
          js_content acme.challengeResponse;
        }

        location /.within.website/ {
          ${anubisConfig}
        }

        include ${pkgs.foxden-http-errors.passthru.nginxConf};

        ${readyzConf readyz}
      '';
      useStockReadyz = !svcConfig.customReadyz;
      baseWebConfig =
        if svcConfig.tls then baseHttpsConfig useStockReadyz else baseHttpConfig useStockReadyz;

      anubisNormalConfig =
        if svcConfig.anubis.enable then
          ''
            server {
              server_name ${builtins.concatStringsSep " " hostMatchers};
              ${anubisListener ""}
              include ${pkgs.foxden-http-errors.passthru.nginxConf};
              ${hostConfig}
            }
          ''
        else
          "";

      normalConfig = ''
        server {
          server_name ${builtins.concatStringsSep " " hostMatchers};
          ${baseWebConfig}
          ${hostConfig}
        }
        ${anubisNormalConfig}
      '';
    in
    {
      config = (
        nixpkgs.lib.mkMerge [
          svc.config
          (nixpkgs.lib.mkIf (
            svcConfig.oAuth.enable && (!svcConfig.oAuth.overrideService)
          ) (mkOauthProxy inputs).config)
          (nixpkgs.lib.mkIf svcConfig.anubis.enable (services.mkNamed "anubis-${name}" inputs).config)
          {
            environment.etc.${confFileEtc} = {
              text = ''
                worker_processes auto;

                error_log stderr notice;
                pid /tmp/nginx.pid;

                events {
                  worker_connections 1024;
                }

                http {
                  access_log off;
                  log_not_found off;

                  include ${package}/conf/mime.types;
                  default_type application/octet-stream;

                  sendfile on;
                  keepalive_timeout 65;

                  map $http_upgrade $connection_upgrade {
                    default upgrade;
                    "" close;
                  }

                  resolver ${nixpkgs.lib.strings.concatStringsSep " " (map foxDenLib.util.bracketIPv6 host.nameservers)};

                  ${foxDenLib.nginx.mkProxiesText "  " config}

                  ${inputs.extraHttpConfig or ""}

                  js_path "/njs/lib/";
                  js_fetch_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

                  server {
                    server_name _;
                    listen 80 default_server;
                    listen [::]:80 default_server;
                    listen 81 default_server proxy_protocol;
                    listen [::]:81 default_server proxy_protocol;
                    ${anubisListener "default_server"}

                    include ${pkgs.foxden-http-errors.passthru.nginxConf};
                    return 404;
                  }

                  ${
                    if svcConfig.tls then
                      ''
                        js_var $njs_acme_server_names "${builtins.concatStringsSep " " hostMatchers}";
                        js_var $njs_acme_account_email "ssl@foxden.network";
                        js_var $njs_acme_dir "${storageRoot}/acme";
                        js_var $njs_acme_directory_uri "https://acme-v02.api.letsencrypt.org/directory";
                        js_shared_dict_zone zone=acme:1m;
                        js_import acme from acme.js;

                        server {
                          server_name _;
                          listen 443 ssl default_server;
                          listen [::]:443 ssl default_server;
                          ${
                            if svcConfig.quic then
                              ''
                                listen 443 quic reuseport;
                                listen [::]:443 quic reuseport;
                              ''
                            else
                              ""
                          }
                          listen 444 ssl default_server proxy_protocol;
                          listen [::]:444 ssl default_server proxy_protocol;
                          http2 on;

                          include ${pkgs.foxden-http-errors.passthru.nginxConf};
                          ssl_reject_handshake on;
                          return 404;
                        }

                        server {
                          server_name ${builtins.concatStringsSep " " hostMatchers};
                          ${baseHttpConfig true}

                          location / {
                            return 301 https://$http_host$request_uri;
                          }
                        }
                      ''
                    else
                      ""
                  }

                ${if rawConfig != null then rawConfig configFuncData else normalConfig}
                }
              '';
              mode = "0600";
            };

            foxDen.hosts.hosts.${svcConfig.host}.webservice = {
              enable = true;
              quicPort = if svcConfig.quic then 443 else 0;
            };

            services.anubis.instances.${name} = nixpkgs.lib.mkIf svcConfig.anubis.enable {
              enable = true;
              user = "anubis-${name}";
              group = name;
              extraFlags = [ "--xff-strip-private=false" ];
              settings = {
                BIND = "/run/anubis/anubis-${name}/anubis.sock";
                METRICS_BIND = "/run/anubis/anubis-${name}/anubis-metrics.sock";
                TARGET = "unix:/run/anubis/anubis-${name}/nginx.sock";
              };
            };

            systemd.services.${name} = {
              after = nixpkgs.lib.mkIf svcConfig.anubis.enable [ "anubis-${name}.service" ];
              wants = nixpkgs.lib.mkIf svcConfig.anubis.enable [ "anubis-${name}.service" ];

              restartTriggers = [ config.environment.etc.${confFileEtc}.text ];
              serviceConfig = {
                DynamicUser = dynamicUser;
                StateDirectory = nixpkgs.lib.strings.removePrefix "/var/lib/" storageRoot;
                LoadCredential = "nginx.conf:${confFilePath}";
                ExecStartPre = [
                  "${pkgs.coreutils}/bin/mkdir -p ${storageRoot}/acme"
                ]
                ++ (
                  if svcConfig.anubis.enable then
                    [
                      "+${pkgs.coreutils}/bin/chmod g+w /run/anubis/anubis-${name}"
                    ]
                  else
                    [ ]
                );
                BindPaths =
                  (if dynamicUser then [ ] else [ storageRoot ])
                  ++ (
                    if svcConfig.anubis.enable then
                      [
                        "/run/anubis/anubis-${name}"
                      ]
                    else
                      [ ]
                  );
                BindReadOnlyPaths = [
                  pkgs.foxden-http-errors.passthru.nginxConf
                  pkgs.foxden-http-errors
                  "${
                    pkgs.fetchurl {
                      url = "https://github.com/nginx/njs-acme/releases/download/v1.0.0/acme.js";
                      hash = "sha256:1aefb709afc2ed81c07fbc5f6ab658782fe99e88569ee868e25d3a6f1e5355cb";
                    }
                  }:/njs/lib/acme.js"
                ];
                ExecStart = "${package}/bin/nginx -g 'daemon off;' -e stderr -c \"\${CREDENTIALS_DIRECTORY}/nginx.conf\"";
              };
              wantedBy = [ "multi-user.target" ];
            };
          }
        ]
      );
    }
  );
}
