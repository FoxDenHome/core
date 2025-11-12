{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.immich;

  hostCfg = foxDenLib.hosts.getByName config svcConfig.host;
  primaryInterface = lib.lists.head (lib.attrsets.attrValues hostCfg.interfaces);
  hostName = foxDenLib.global.dns.mkHost primaryInterface.dns;
  proto = if svcConfig.tls then "https" else "http";

  clipModelName = "ViT-H-14-378-quickgelu__dfn5b";
  facialRecognitionModelName = "antelopev2";
in
{
  options.foxDen.services.immich = {
    mediaDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory to store Immich media";
    };
  }
  // services.http.mkOptions {
    svcName = "immich";
    name = "Immich image server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        name = "immich-server";
        gpu = true;
        inherit svcConfig pkgs config;
      }).config
      (services.make {
        name = "immich-machine-learning";
        gpu = true;
        inherit svcConfig pkgs config;
      }).config
      (foxDenLib.services.redis.make {
        inherit pkgs config svcConfig;
        name = "immich";
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-immich";
        target = "proxy_pass http://127.0.0.1:${builtins.toString config.services.immich.port};";
      }).config
      {
        foxDen.services.immich.oAuth.overrideService = true;

        foxDen.services.kanidm.oauth2 =
          let
            baseCfg = (
              services.http.mkOauthConfig {
                inherit svcConfig config;
                oAuthCallbackUrl = "/auth/login";
              }
            );
          in
          lib.mkIf svcConfig.oAuth.enable {
            ${svcConfig.oAuth.clientId} = baseCfg // {
              preferShortUsername = true;
              originUrl = baseCfg.originUrl ++ [ "app.immich:///oauth-callback" ];
              claimMaps = {
                "immich_role" = {
                  joinType = "ssv";
                  valuesByGroup = {
                    "superadmins" = [ "admin" ];
                  };
                };
              };
            };
          };

        foxDen.services.postgresql = {
          enable = true;
          services = [
            {
              database = "immich";
              service = "immich-server";
            }
            {
              database = "immich";
              service = "immich-machine-learning";
            }
          ];
        };

        systemd.services =
          let
            cfg = {
              confinement.packages = [
                config.services.postgresql.package
              ];
              path = [
                config.services.postgresql.package
              ];
              serviceConfig = {
                BindPaths = [
                  svcConfig.mediaDir
                ];
                BindReadOnlyPaths = [
                  config.services.immich.environment.IMMICH_CONFIG_FILE
                ];
                Environment = [
                  "MPLCONFIGDIR=/var/cache/immich/matplotlib"
                ];
              };
            };
          in
          {
            immich-server = cfg;
            immich-machine-learning = cfg;
          };

        services.immich = {
          host = "127.0.0.1";
          enable = true;
          accelerationDevices = [ ];
          mediaLocation = svcConfig.mediaDir;
          database = {
            createDB = false;
          };
          redis = {
            enable = true;
            host = "127.0.0.1";
            port = 6379;
          };
          machine-learning = {
            environment = {
              MACHINE_LEARNING_MODEL_TTL = "0";
              MACHINE_LEARNING_PRELOAD__CLIP__TEXTUAL = clipModelName;
              MACHINE_LEARNING_PRELOAD__CLIP__VISUAL = clipModelName;
              MACHINE_LEARNING_PRELOAD__FACIAL_RECOGNITION__DETECTION = facialRecognitionModelName;
              MACHINE_LEARNING_PRELOAD__FACIAL_RECOGNITION__RECOGNITION = facialRecognitionModelName;
            };
          };
          settings = {
            ffmpeg = {
              crf = 23;
              threads = 0;
              preset = "ultrafast";
              targetVideoCodec = "hevc";
              acceptedVideoCodecs = [
                "h264"
                "hevc"
              ];
              targetAudioCodec = "aac";
              acceptedAudioCodecs = [
                "aac"
                "mp3"
                "libopus"
                "pcm_s16le"
              ];
              acceptedContainers = [
                "mov"
                "ogg"
                "webm"
              ];
              targetResolution = "1080";
              maxBitrate = "0";
              bframes = -1;
              refs = 0;
              gopSize = 0;
              temporalAQ = false;
              cqMode = "auto";
              twoPass = false;
              preferredHwDevice = "auto";
              transcode = "required";
              tonemap = "hable";
              accel = "nvenc";
              accelDecode = true;
            };
            backup = {
              database = {
                enabled = true;
                cronExpression = "0 02 * * *";
                keepLastAmount = 14;
              };
            };
            job = {
              backgroundTask = {
                concurrency = 5;
              };
              smartSearch = {
                concurrency = 2;
              };
              metadataExtraction = {
                concurrency = 5;
              };
              faceDetection = {
                concurrency = 2;
              };
              search = {
                concurrency = 5;
              };
              sidecar = {
                concurrency = 5;
              };
              library = {
                concurrency = 5;
              };
              migration = {
                concurrency = 5;
              };
              thumbnailGeneration = {
                concurrency = 3;
              };
              videoConversion = {
                concurrency = 1;
              };
              notifications = {
                concurrency = 5;
              };
            };
            logging = {
              enabled = true;
              level = "log";
            };
            machineLearning = {
              enabled = true;
              urls = [ "http://127.0.0.1:3003" ];
              clip = {
                enabled = true;
                modelName = clipModelName;
              };
              duplicateDetection = {
                enabled = true;
                maxDistance = 0.01;
              };
              facialRecognition = {
                enabled = true;
                modelName = facialRecognitionModelName;
                minScore = 0.7;
                maxDistance = 0.5;
                minFaces = 3;
              };
            };
            map = {
              enabled = true;
              lightStyle = "https://tiles.immich.cloud/v1/style/light.json";
              darkStyle = "https://tiles.immich.cloud/v1/style/dark.json";
            };
            reverseGeocoding = {
              enabled = true;
            };
            metadata = {
              faces = {
                import = false;
              };
            };
            oauth = {
              autoLaunch = true;
              autoRegister = true;
              buttonText = "Login with FoxDen";
              clientId = if svcConfig.oAuth.enable then svcConfig.oAuth.clientId else "";
              clientSecret = "";
              defaultStorageQuota = null;
              enabled = svcConfig.oAuth.enable;
              issuerUrl =
                if svcConfig.oAuth.enable then
                  "https://auth.foxden.network/oauth2/openid/${svcConfig.oAuth.clientId}"
                else
                  "";
              mobileOverrideEnabled = false;
              mobileRedirectUri = "";
              scope = "openid email profile";
              signingAlgorithm = "ES256";
              profileSigningAlgorithm = "none";
              storageLabelClaim = "preferred_username";
              storageQuotaClaim = "immich_quota";
            };
            passwordLogin = {
              enabled = false;
            };
            storageTemplate = {
              enabled = false;
              hashVerificationEnabled = true;
              template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}";
            };
            image = {
              thumbnail = {
                format = "webp";
                size = 250;
                quality = 80;
              };
              preview = {
                format = "jpeg";
                size = 1440;
                quality = 80;
              };
              colorspace = "p3";
              extractEmbedded = false;
            };
            newVersionCheck = {
              enabled = true;
            };
            trash = {
              enabled = true;
              days = 30;
            };
            theme = {
              customCss = "";
            };
            library = {
              scan = {
                enabled = true;
                cronExpression = "0 0 * * *";
              };
              watch = {
                enabled = false;
              };
            };
            server = {
              externalDomain = "${proto}://${hostName}";
              loginPageMessage = "";
            };
            notifications = {
              smtp = {
                enabled = false;
                from = "";
                replyTo = "";
                transport = {
                  ignoreCert = false;
                  host = "";
                  port = 587;
                  username = "";
                  password = "";
                };
              };
            };
            user = {
              deleteDelay = 7;
            };
          };
        };
      }
    ]
  );
}
