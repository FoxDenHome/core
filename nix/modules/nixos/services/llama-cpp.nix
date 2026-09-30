{
  foxDenLib,
  pkgs,
  lib,
  config,
  ...
}:
let
  services = foxDenLib.services;

  svcConfig = config.foxDen.services.llama-cpp;

  package = pkgs.llama-cpp.override {
    vulkanSupport = true;
    rocmSupport = false;
  };
in
{
  options.foxDen.services.llama-cpp = {
    model = lib.mkOption {
      type = lib.types.str;
      description = "HuggingFace model reference (repo:quant) for llama-server to download and serve";
      default = "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };
    contextSize = lib.mkOption {
      type = lib.types.int;
      default = 16384;
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  }
  // services.mkOptions {
    name = "llama.cpp LLM server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "llama-cpp";
        gpu = true;
      }).config
      {
        systemd.services.llama-cpp = {
          serviceConfig = {
            DynamicUser = true;
            Type = "simple";
            ExecStart = lib.escapeShellArgs (
              [
                "${package}/bin/llama-server"
                "--host"
                "::"
                "--port"
                (toString svcConfig.port)
                "--hf-repo"
                svcConfig.model
                "--n-gpu-layers"
                "999"
                "--ctx-size"
                (toString svcConfig.contextSize)
                "--parallel"
                "1"
                "--jinja"
              ]
              ++ svcConfig.extraFlags
            );
            Environment = [
              "LLAMA_CACHE=/var/cache/llama-cpp"
            ];
            CacheDirectory = "llama-cpp";
          };

          wantedBy = [ "multi-user.target" ];
        };
      }
    ]
  );
}
