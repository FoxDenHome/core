{ pkgs, ... }:
let
  gradle = pkgs.gradleFromWrapper {
    wrapperPropertiesPath = ./gradle-wrapper.properties;
    defaultJava = pkgs.openjdk8;
  };
  version = "1.0.0";

  buildGradleApplication = (
    pkgs.buildGradleApplication.override {
      stdenvNoCC = pkgs.stdenvNoCC // {
        mkDerivation = (
          input:
          pkgs.stdenvNoCC.mkDerivation (
            input
            // {
              installPhase = ''
                mkdir -p $out/share
                mv war $out/share/circuitjs
                mv build/gwt/out/circuitjs1 $out/share/circuitjs/
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
  pname = "circuitjs";
  inherit gradle version;

  buildTask = "compileGwt";

  src = pkgs.stdenvNoCC.mkDerivation {
    name = "circuitjs-src";
    inherit version;

    src = pkgs.fetchFromGitHub {
      owner = "johnnewto";
      repo = "circuitjs1";
      rev = "10a9037254711e67363a0f35d4daf32f28d3bed3";
      sha256 = "sha256-Z/gJeVbVQEo/LYxDJFSX1hsMOdOTYeg0i2usZx24LLY=";
    };

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
}
