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
        # Patched openjpeg: adds two env-gated differential-oracle dumps —
        # JP2Z_DUMP_T1 (cblk coefficient dump used by M3 EBCOT oracle
        # tests, compare our cleanroom decodeCblk output byte-perfect vs
        # OpenJPEG's opj_t1_decode_cblk) and JP2Z_DUMP_T2 (per-packet
        # (tile, pino, l/r/c/p, offset) trace from opj_t2_decode_packets,
        # used to diff the tier-2 walker's packet sequencing — this is
        # how the e1_colr POC/PCRL divergence was pinned to 3 packets).
        # Both are no-ops at runtime when their env vars are unset.
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
              # FLEET FLOOR — tests run ReleaseSafe (fleet finding 2026-07-01).
              # ReleaseFast compiles OUT the runtime safety checks (integer
              # overflow, bounds, illegal cast), so a green ReleaseFast suite
              # cannot see UB — it passes *because* the check that would have
              # failed it is gone. rarz was carrying three real crashers behind
              # a fully green ReleaseFast suite.
              #
              # Enforced HERE rather than as a per-module `.optimize` in
              # build.zig: Zig honours per-module optimize, so pinning only the
              # test module would leave the imported library code at
              # ReleaseFast. Passing -Doptimize on the command line flips the
              # entire test compilation in one shot.
              #
              # The shipped artifact and benchmarks stay ReleaseFast — this
              # applies to the test build only.
              timeout 600 zig build test -Doptimize=ReleaseSafe ${pkgs.lib.concatStringsSep " " zigBuildFlags} \
                || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ zigPkg pkgs.hyperfine pkgs.jq pkgs.coreutils ];
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
