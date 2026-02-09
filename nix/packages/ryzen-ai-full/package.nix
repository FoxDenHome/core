{
  lib,
  pkgs,
  ...
}:

let
  version = "1.7.0";

  dataDir = "$src/Ryzen-AI-CVML-Library/linux/onnx/ryzen14";

  vaip-runtime = pkgs.stdenv.mkDerivation {
    pname = "vaip-runtime";
    inherit version;

    src = pkgs.fetchgit {
      url = "https://github.com/amd/RyzenAI-SW.git";
      rev = "0b65628f1caacf0fbe3fd2cb4ed6bae0437a4155"; # TODO: Temporary override because 1.7.0 is broken "v${version}";
      sha256 = "sha256-ji7GatS2UZn96VnCpdBh396mKXEdYAGnqerKK0cL0fg=";
      fetchLFS = true;
    };

    nativeBuildInputs = with pkgs; [
      autoPatchelfHook
    ];

    buildInputs =
      with pkgs;
      let
        boostVersion = "1.74.0";
        boostBase = boost178.overrideAttrs (oldAttrs: {
          version = boostVersion;
          src = pkgs.fetchurl {
            version = boostVersion;
            urls = [
              "mirror://sourceforge/boost/boost_${builtins.replaceStrings [ "." ] [ "_" ] boostVersion}.tar.bz2"
              "https://boostorg.jfrog.io/artifactory/main/release/${boostVersion}/source/boost_${
                builtins.replaceStrings [ "." ] [ "_" ] boostVersion
              }.tar.bz2"
            ];
            # SHA256 from http://www.boost.org/users/history/version_1_74_0.html
            sha256 = "sha256:83bfc1507731a0906e387fc28b7ef5417d591429e51e788417fe9ff025e116b1";
          };
        });
      in
      [
        stdenv.cc.cc.lib
        zlib
        (boostBase.override {
          boost-build = boost-build.override {
            useBoost = boostBase;
          };
        })
        protobuf
        abseil-cpp
        xrt
        python310
      ];

    unpackPhase = "true";

    installPhase = ''
      mkdir -p $out/lib $out/share/xclbin $out/share/vaip

      cp -P ${dataDir}/*.so* $out/lib/
      cp -P ${dataDir}/*.xclbin $out/share/xclbin/
      cp -P ${dataDir}/vaip_config*.json $out/share/vaip/vaip_config.json
    '';

    meta = with lib; {
      description = "AMD VAIP runtime for Ryzen AI NPU";
      license = licenses.unfree;
      platforms = [ "x86_64-linux" ];
    };
  };

in
pkgs.symlinkJoin {
  name = "ryzen-ai-full-${version}";

  paths = with pkgs; [
    xrt-amdxdna
    onnxruntime-vitisai
    dynamic-dispatch
    vaip-runtime
  ];
}
