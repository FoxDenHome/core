{ pkgs, ... }:
let
  version = "0.03";

  srcPkgs = pkgs.stdenvNoCC.mkDerivation {
    name = "circuitjs-src";
    src = pkgs.fetchFromGitHub {
      owner = "johnnewto";
      repo = "circuitjs1";
      rev = "v${version}";
      sha256 = "sha256-tU07va+Ud7lPb9p4zKeGiAspgGbonBAUxvNwwVR1XVw=";
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
    chmod -R 755 $out/share/circuitjs
    cp -r ${./public}/. $out/share/circuitjs/
  '';
}
