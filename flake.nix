{
  description = "jp2z — cleanroom JPEG 2000 (T.800) decoder in Zig with a C FFI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # ITU-T T.803 / ISO 15444-4 conformance bitstreams + regression
    # corpus, pinned to a known-good commit. Used as the Phase 2
    # cleanroom oracle (byte-perfect compare vs openjpeg over the
    # full ~1,200-file suite). Exposed to tests via $OPENJPEG_DATA.
    # We vendor a tiny ~1MB subset directly in tests/unit/fixtures/
    # for fast offline iteration; this input is the broad corpus.
    openjpeg-data = {
      url = "github:uclouvain/openjpeg-data/39524bd3a601d90ed8e0177559400d23945f96a9";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, openjpeg-data }:
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
        # Patched openjpeg: adds a JP2Z_DUMP_T1 env-gated cblk
        # coefficient dump used by M3 EBCOT oracle tests (compare our
        # cleanroom decodeCblk output byte-perfect vs OpenJPEG's
        # opj_t1_decode_cblk). The patch is a no-op at runtime when
        # the env var is unset.
        openjpegPatched = pkgs.openjpeg.overrideAttrs (old: {
          patches = (old.patches or []) ++ [ ./patches/openjpeg-cblk-dump.patch ];
        });
        openjpegDev = openjpegPatched.dev;
        openjpegLib = openjpegPatched;

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

        checks = {
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
              export OPENJPEG_DATA=${openjpeg-data}
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
            export OPENJPEG_DATA=${openjpeg-data}
          '';
        };
      });
}
