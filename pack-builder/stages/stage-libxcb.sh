#!/usr/bin/env bash
# Stage "libxcb" (arm64 container): rebuilds libxcb.so.1 from the upstream release matching
# Debian's libxcb1, with the PMBOS_TMPDIR socket-directory patch. Only the core library is
# replaced in the imagefs (same upstream version -> identical ABI).
PB_LOG_PREFIX=libxcb
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
out="$BUILD/libxcb"
trap 'fix_owner "$out"' EXIT
need_cmd gcc make tar patch strip readelf

patchfile="$PB/patches/libxcb-$LIBXCB_VERSION-pmbos-tmpdir.patch"
[ -f "$patchfile" ] || die "no libxcb patch for version $LIBXCB_VERSION ($patchfile)"

fresh_dir "$out"
src="$out/src"
mkdir -p "$src"
tar -xf "$SRC/libxcb-$LIBXCB_VERSION.tar.xz" -C "$src" --strip-components=1
log "applying $(basename "$patchfile")"
(cd "$src" && patch -p1 --fuzz=0 < "$patchfile")

(
    cd "$src"
    ./configure --prefix=/usr --libdir="/usr/lib/aarch64-linux-gnu" --disable-static \
        --disable-devel-docs --without-doxygen CFLAGS="-O2 -g0" >/dev/null
    # whole src/ dir: the generated protocol headers are BUILT_SOURCES of the default target
    make -C src -j"$JOBS" >/dev/null
)
lib="$(readlink -f "$src/src/.libs/libxcb.so.1")"
[ -f "$lib" ] || die "libxcb.so.1 was not built"
cp "$lib" "$out/$(basename "$lib")"
strip --strip-unneeded "$out/$(basename "$lib")"

soname="$(readelf -d "$out/$(basename "$lib")" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
[ "$soname" = "libxcb.so.1" ] || die "unexpected SONAME: $soname"
grep -q PMBOS_TMPDIR "$out/$(basename "$lib")" || die "patch not present in the built library"
echo "$(basename "$lib")" > "$out/LIBFILE"
rm -rf "$src"
log "built $(basename "$lib") (patched)"
