{ pkgs, ... }:
let
  version = "1.0.0";

  srcPkgs = pkgs.stdenvNoCC.mkDerivation {
    name = "circuitjs-src";
    src = pkgs.fetchFromGitHub {
      owner = "johnnewto";
      repo = "circuitjs1";
      rev = "10a9037254711e67363a0f35d4daf32f28d3bed3";
      sha256 = "sha256-Z/gJeVbVQEo/LYxDJFSX1hsMOdOTYeg0i2usZx24LLY=";
    };
    inherit version;

    unpackPhase = "true";
    # ./gradlew --refresh-dependencies --write-verification-metadata sha256 --write-locks dependencies
    installPhase = ''
      cp -r $src $out

      chmod -R 755 $out
      mkdir -p $out/gradle
      chmod 755 $out/gradle

      cp ${./settings.gradle} $out/settings.gradle
      cp ${./verification-metadata.xml} $out/gradle/verification-metadata.xml

      cd $out && patch -p1 -i ${./circuitjs.patch}
    '';
  };

  javaPkg =
    let
      gradle = pkgs.gradleFromWrapper {
        wrapperPropertiesPath = ./gradle-wrapper.properties;
        defaultJava = pkgs.openjdk8;
      };

      buildGradleApplication = (
        pkgs.buildGradleApplication.override {
          stdenvNoCC = pkgs.stdenvNoCC // {
            mkDerivation = (
              input:
              pkgs.stdenvNoCC.mkDerivation (
                input
                // {
                  installPhase = ''
                    mv war $out
                    mv build/gwt/out/circuitjs1 $out/
                  '';
                  nativeBuildInputs = [ gradle ];
                  postFixup = "true";
                }
              )
            );
          };
        }
      );
    in
    buildGradleApplication {
      pname = "circuitjs-java";
      src = srcPkgs;
      inherit gradle version;

      buildTask = "compileGwt";
    };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "circuitjs";
  src = javaPkg;
  inherit version;

  unpackPhase = "true";
  installPhase = ''
    mkdir -p $out/share
    cp -r $src $out/share/circuitjs
    chmod 755 $out/share/circuitjs/circuitjs1/circuits
    cp ${./startup.txt} $out/share/circuitjs/circuitjs1/circuits/startup.txt
  '';
}
