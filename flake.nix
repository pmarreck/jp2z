{
  description = "jp2z — cleanroom JPEG 2000 (T.800) decoder in Zig with a C FFI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "jp2z";
        version = "0.0.1";
        zigPkg = pkgs.zig;

        # Phase-1 backend. Retires milestone by milestone over Phase 2.
        # After M6 (cleanroom complete) this dependency is dropped
        # from the runtime build entirely; openjpeg only stays as a
        # build-time oracle imported via `jp2z.internal.openjpegDecode`
        # for byte-perfect regression testing (same pattern jpegz
        # uses for libjpeg-turbo today).
        openjpegDev = pkgs.openjpeg.dev;
        openjpegLib = pkgs.openjpeg;

        commonBuildInputs = [
          openjpegLib
        ];

        zigBuildFlags = [
          "-Dopenjpeg-include=${openjpegDev}/include/openjpeg-2.5"
          "-Dopenjpeg-lib=${openjpegLib}/lib"
        ];
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ zigPkg ];
          buildInputs = commonBuildInputs;
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            zig build -Doptimize=ReleaseFast --prefix $out ${pkgs.lib.concatStringsSep " " zigBuildFlags}
          '';
          dontInstall = true;
        };

        checks.${system} = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ zigPkg ];
            buildInputs = commonBuildInputs;
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              timeout 600 zig build test ${pkgs.lib.concatStringsSep " " zigBuildFlags} \
                || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ zigPkg pkgs.hyperfine ];
          buildInputs = commonBuildInputs;
          shellHook = ''
            echo "jp2z devShell — zig ${zigPkg.version}, openjpeg ${openjpegLib.version} (Phase 1 backend)"
            export OPENJPEG_INCLUDE=${openjpegDev}/include/openjpeg-2.5
            export OPENJPEG_LIB=${openjpegLib}/lib
          '';
        };
      });
}
