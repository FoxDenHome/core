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
    contextSize = lib.mkOption {
      type = lib.types.int;
      default = 16384;
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  }
  // services.http.mkOptions {
    name = "llama.cpp LLM server";
  };

  config = lib.mkIf svcConfig.enable (
    lib.mkMerge [
      (services.make {
        inherit svcConfig pkgs config;
        name = "llama-cpp";
        gpu = true;
      }).config
      (services.http.make {
        inherit svcConfig pkgs config;
        name = "http-llama-cpp";
        target = "proxy_pass http://127.0.0.1:8080;";
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
                "127.0.0.1"
                "--port"
                "8080"
                "--hf-repo"
                svcConfig.model
                "--n-gpu-layers"
                "999"
                "--ctx-size"
                (toString svcConfig.contextSize)
                "--parallel"
                "1"
                # q8_0 V cache doubles long-context prompt processing on the 780M (Vulkan)
                # Do not raise --ubatch-size to 2048 with flash-attn, it hangs the GPU compute ring
                "--flash-attn"
                "on"
                "--cache-type-v"
                "q8_0"
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
