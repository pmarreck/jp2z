# shellcheck shell=bash
# Platform vocabulary for jp2z's build and dev scripts (fleet naming
# contract, cross-platform-project-build-arch skill, 2026-10-23). Sourced,
# never executed. Every function prints its answer on stdout and returns
# non-zero, printing nothing, for anything outside the declared matrix:
# an unknown platform is never silently mapped to a default.
#
# PF is <OS>-<ARCH> with OS in {linux, macos, mswin} and ARCH in {amd64,
# arm64}. Compiler triples keep Zig's spelling and are translated here, at
# the tool boundary, and nowhere else. Tests: tests/cli/platform_test.

# The declared five-target matrix, in build order.
jp2z_pf_matrix() { echo "linux-amd64 linux-arm64 macos-arm64 mswin-amd64 mswin-arm64"; }

# Host PF from `uname -s` and `uname -m` (pass them in; this function does
# not read the machine, so it is testable as a classifier). WSL reports
# Linux and uses Linux outputs.
jp2z_pf_from_uname() {
	local os arch
	case "$1" in
		Linux) os=linux ;;
		Darwin) os=macos ;;
		MINGW*|MSYS*|CYGWIN*|Windows_NT) os=mswin ;;
		*) return 1 ;;
	esac
	case "$2" in
		x86_64|amd64|AMD64) arch=amd64 ;;
		aarch64|arm64|ARM64) arch=arm64 ;;
		*) return 1 ;;
	esac
	jp2z_pf_known "$os-$arch" || return 1
	echo "$os-$arch"
}

jp2z_pf_known() {
	local pf
	for pf in $(jp2z_pf_matrix); do [ "$pf" = "$1" ] && return 0; done
	return 1
}

# Host PF of the machine running this shell.
jp2z_pf_host() { jp2z_pf_from_uname "$(uname -s)" "$(uname -m)"; }

# Zig target triple for a PF. Linux products are static musl; Windows uses
# the MinGW (gnu) ABI that Zig cross-compiles without an SDK.
jp2z_pf_triple() {
	case "$1" in
		linux-amd64) echo x86_64-linux-musl ;;
		linux-arm64) echo aarch64-linux-musl ;;
		macos-arm64) echo aarch64-macos ;;
		mswin-amd64) echo x86_64-windows-gnu ;;
		mswin-arm64) echo aarch64-windows-gnu ;;
		*) return 1 ;;
	esac
}

# ABI variant directory for a PF: musl or gnu, or "none" when it does not
# apply (macOS). "none" is a value for callers, never a path component.
jp2z_pf_variant() {
	case "$1" in
		linux-amd64|linux-arm64) echo musl ;;
		mswin-amd64|mswin-arm64) echo gnu ;;
		macos-arm64) echo none ;;
		*) return 1 ;;
	esac
}

jp2z_pf_exe_suffix() {
	case "$1" in
		mswin-amd64|mswin-arm64) echo .exe ;;
		linux-amd64|linux-arm64|macos-arm64) echo "" ;;
		*) return 1 ;;
	esac
}

# Project-relative install prefix: zig-out/<PF>/[<VARIANT>/]<profile>.
jp2z_prefix() {
	local variant
	case "$2" in Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;; *) return 1 ;; esac
	variant=$(jp2z_pf_variant "$1") || return 1
	if [ "$variant" = none ]; then echo "zig-out/$1/$2"; else echo "zig-out/$1/$variant/$2"; fi
}

# Extended-regex a libmagic (`file -b`) description must match for a
# product of this PF: the right container, architecture and, for Linux,
# static linking (musl products carry no loader). The flake's per-target
# derivations check the same patterns at build time.
jp2z_pf_magic() {
	case "$1" in
		linux-amd64) echo 'ELF 64-bit LSB executable, x86-64.*statically linked' ;;
		linux-arm64) echo 'ELF 64-bit LSB executable, ARM aarch64.*statically linked' ;;
		macos-arm64) echo 'Mach-O 64-bit arm64 executable' ;;
		mswin-amd64) echo 'PE32\+ executable.*x86-64' ;;
		mswin-arm64) echo 'PE32\+ executable.*Aarch64' ;;
		*) return 1 ;;
	esac
}

# Prefix for host-native development tools (sweep-one, probe-label,
# coverage-stats, tile-hist): built for the native target and linked
# against the dev shell's libc and OpenJPEG, so they are neither musl nor
# portable. "native" is a deliberate, documented separation from the
# gnu/musl product variants and is never published or put on PATH.
jp2z_dev_prefix() {
	local pf
	case "$1" in Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;; *) return 1 ;; esac
	pf=$(jp2z_pf_host) || return 1
	echo "zig-out/$pf/native/$1"
}
