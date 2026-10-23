# shellcheck shell=bash
# Publication of bin/<PF>/ entrypoints (cross-platform-project-build-arch
# convention). Sourced; needs platform.bash. Tests: tests/cli/publish_test.
#
# jp2z_publish ROOT PF PRODUCT
#   Publish PRODUCT (an installed jp2z executable under ROOT) as
#   ROOT/bin/PF/jp2z[.exe] only if its header matches PF according to an
#   independent oracle (libmagic `file -b`, or JP2Z_MAGIC_CMD in tests).
#   Linux and macOS entrypoints are relative symlinks; Windows entrypoints
#   are regular .exe copies, so running them needs no symlink privileges.
#   The new entry is built under a unique temporary name and renamed over
#   the old one, so a reader always sees a complete entrypoint, competing
#   publishers leave exactly one winner, and any failure before the rename
#   leaves the previous entrypoint untouched.
jp2z_publish() {
	local root=$1 pf=$2 product=$3 want magic dir exe tmp rel
	jp2z_pf_known "$pf" || { echo "publish: unsupported platform '$pf'" >&2; return 1; }
	[ -f "$product" ] || { echo "publish: no product at $product" >&2; return 1; }
	want=$(jp2z_pf_magic "$pf") || return 1
	if [ -n "${JP2Z_MAGIC_CMD:-}" ]; then magic=$("$JP2Z_MAGIC_CMD" "$product"); else magic=$(file -b -L "$product"); fi
	if ! printf '%s\n' "$magic" | grep -Eq "$want"; then
		echo "publish: $product is not a $pf executable ($magic); bin/$pf left unchanged" >&2
		return 1
	fi
	case "$product" in "$root"/*) rel=${product#"$root"/} ;; *) echo "publish: $product is outside $root" >&2; return 1 ;; esac
	exe=jp2z$(jp2z_pf_exe_suffix "$pf")
	dir=$root/bin/$pf
	mkdir -p "$dir" || return 1
	tmp=$(mktemp "$dir/.jp2z-publish.XXXXXX") || return 1
	case "$pf" in
		mswin-*)
			cp -f -- "$product" "$tmp" && chmod 755 "$tmp" || { rm -f -- "$tmp"; return 1; } ;;
		*)
			rm -f -- "$tmp" && ln -s -- "../../$rel" "$tmp" || { rm -f -- "$tmp"; return 1; } ;;
	esac
	mv -f -- "$tmp" "$dir/$exe" || { rm -f -- "$tmp"; return 1; }
	echo "published bin/$pf/$exe -> $rel"
}
