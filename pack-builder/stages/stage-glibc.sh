#!/usr/bin/env bash
# Stage "glibc" (arm64 container): rebuilds Debian's glibc at EXACTLY GLIBC_DEBIAN_VERSION (= the
# version of the stock ld.so the APK ships, pmbos/tools/loader/VERSION) with
#   patches/glibc-<upstream>-pmbos-rootfs.patch: libc looks up /etc/resolv.conf, /etc/hosts,
#     /etc/nsswitch.conf, /etc/passwd, ..., /etc/localtime, /usr/share/zoneinfo and /bin/sh below
#     $PMBOS_ROOTFS when that variable is set;
#   patches/glibc-<upstream>-pmbos-execve.patch: execve() runs dynamically linked glibc programs
#     (and "#!" scripts) through $PMBOS_LOADER (Android "loader in jniLibs" exec mode)
# (see the patch headers).
#   pinned source package from stage fetch (sha256) -> dpkg-source -x (Debian quilt series)
#   -> our patches (--fuzz=0) -> debian/rules install_libc with nocheck (only the "libc" pass:
#   no locales-all, no test suite, no .deb packaging)
#   -> $BUILD/glibc/overlay: exactly the files of Debian's libc6 package (debian/debhelper.in/
#      libc.install: ld.so, lib/<triplet>/*.so*, usr/lib/<triplet>/gconv), merged-/usr layout,
#      stripped like dh_strip
#   -> $BUILD/glibc/stock-loader/libpmbld.so: Debian's unmodified ld.so of the same version from
#      the pinned libc6 .deb (sha256 = LOADER_SHA256 = the APK's libpmbld.so)
#   -> self-tests: src/glibc-rootfs-test.c under the new loader; tests/execve-redirect-hosttest.sh
#      (unit test of the redirect logic + classification of real binaries); src/glibc-execve-test.c
#      twice, PMBOS_LOADER = the rebuilt ld.so and = the stock ld.so (the device combination).
# The rootfs stage overlays these files onto the imagefs.
PB_LOG_PREFIX=glibc
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
out="$BUILD/glibc"
trap 'fix_owner "$out"' EXIT
need_cmd dpkg-source dpkg-parsechangelog dpkg-deb make gcc patch strip readelf awk
TRIPLET=aarch64-linux-gnu
LD=ld-linux-aarch64.so.1

[ "$(dpkg --print-architecture)" = arm64 ] || die "stage glibc must run in the arm64 container"

fresh_dir "$out"
srcroot="$out/src"
mkdir -p "$srcroot"

# --- source: the pinned Debian source package (stage fetch, sha256-verified) -------------------
dsc=""
deb=""
while read -r name sha _; do
    f="$SRC/glibc/$name"
    [ -f "$f" ] || die "$f missing: run stage fetch first"
    verify_sha256 "$f" "$sha"
    case "$name" in
        *.deb) deb="$f" ;;
        *.dsc) dsc="$name"; cp "$f" "$srcroot/" ;;
        *) cp "$f" "$srcroot/" ;;
    esac
done < <(glibc_inputs)
[ -n "$dsc" ] && [ -n "$deb" ] || die "glibc_inputs: no .dsc or no .deb"
log "dpkg-source -x $dsc"
# dpkg-source verifies the .dsc checksums; it can only warn about the signature (no
# debian-keyring here) - the files are pinned by sha256 instead.
(cd "$srcroot" && dpkg-source -x "$dsc" glibc >/dev/null)
src="$srcroot/glibc"
debver="$(dpkg-parsechangelog -l "$src/debian/changelog" -S Version)"
[ "$debver" = "$GLIBC_DEBIAN_VERSION" ] || die "source package is glibc $debver, pinned $GLIBC_DEBIAN_VERSION"
upver="${debver%%-*}"
for name in pmbos-rootfs pmbos-execve; do
    patchfile="$PB/patches/glibc-$upver-$name.patch"
    [ -f "$patchfile" ] || die "no $name patch for glibc $upver ($debver): $patchfile"
    log "glibc $debver: applying $(basename "$patchfile")"
    (cd "$src" && patch -p1 --fuzz=0 < "$patchfile" >/dev/null) \
        || die "$(basename "$patchfile") does not apply to glibc $debver"
done

# --- build: only Debian's "libc" pass, installed into debian/tmp -------------------------------
log "building glibc $debver (debian/rules install_libc, nocheck, -j$JOBS) - long under qemu"
t0=$SECONDS
(
    cd "$src"
    export DEB_BUILD_OPTIONS="nocheck nodoc parallel=$JOBS"
    make -f debian/rules install_libc > "$out/build.log" 2>&1
) || { tail -n 60 "$out/build.log" >&2; die "glibc build failed (full log: $out/build.log)"; }
log "glibc built in $((SECONDS - t0))s"
tmp="$src/debian/tmp"
[ -d "$tmp/lib/$TRIPLET" ] || die "debian/tmp/lib/$TRIPLET missing after install_libc"

# --- overlay = libc6 package content (libc.install), merged-/usr --------------------------------
ov="$out/overlay"
mkdir -p "$ov/lib" "$ov/usr/lib/$TRIPLET"
# Debian's install_% moves the loader to slibdir and leaves an ABSOLUTE symlink
# debian/tmp/lib/$LD -> /lib/$TRIPLET/$LD: never resolve it (readlink -f would pick the
# container's stock loader); take the regular file inside debian/tmp only.
ld_real=""
for c in "$tmp/lib/$TRIPLET/$LD" "$tmp/lib/$LD"; do
    if [ -f "$c" ] && [ ! -L "$c" ]; then ld_real="$c"; break; fi
done
[ -n "$ld_real" ] || die "built loader $LD not found as a regular file in debian/tmp"
install -m 0755 "$ld_real" "$ov/lib/$LD"
strip --strip-debug --remove-section=.comment "$ov/lib/$LD"   # keep .symtab (valgrind, gdb)
n=0
for f in "$tmp/lib/$TRIPLET"/*.so*; do
    b="$(basename "$f")"
    [ "$b" = "$LD" ] && continue
    if [ -L "$f" ]; then
        case "$(readlink "$f")" in /*) die "absolute symlink in debian/tmp: $f" ;; esac
        cp -P "$f" "$ov/usr/lib/$TRIPLET/$b"
        continue
    fi
    [ -f "$f" ] || continue
    mode=0644
    case "$b" in libc.so.*) mode=0755 ;; esac   # libc.so.6 prints its version when executed
    install -m "$mode" "$f" "$ov/usr/lib/$TRIPLET/$b"
    strip --strip-unneeded --remove-section=.comment --remove-section=.note "$ov/usr/lib/$TRIPLET/$b"
    n=$((n + 1))
done
[ -d "$tmp/usr/lib/$TRIPLET/gconv" ] || die "gconv modules missing in debian/tmp"
cp -a "$tmp/usr/lib/$TRIPLET/gconv" "$ov/usr/lib/$TRIPLET/gconv"
find "$ov/usr/lib/$TRIPLET/gconv" -type f -name '*.so' \
    -exec strip --strip-unneeded --remove-section=.comment --remove-section=.note {} +
for req in libc.so.6 libm.so.6 libresolv.so.2 libnss_files.so.2 libnss_dns.so.2 libpthread.so.0 libdl.so.2; do
    [ -f "$ov/usr/lib/$TRIPLET/$req" ] || die "overlay lacks $req"
done
libc="$ov/usr/lib/$TRIPLET/libc.so.6"
grep -q PMBOS_ROOTFS "$libc" || die "PMBOS_ROOTFS patch not present in the built libc.so.6"
grep -q PMBOS_LOADER_LIBPATH "$libc" || die "PMBOS_LOADER execve patch not present in the built libc.so.6"
grep -qaF "(Debian GLIBC $GLIBC_DEBIAN_VERSION)" "$libc" \
    || die "built libc.so.6 does not identify as Debian GLIBC $GLIBC_DEBIAN_VERSION"
soname="$(readelf -d "$libc" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
[ "$soname" = libc.so.6 ] || die "unexpected libc SONAME: $soname"
log "overlay: $LD + $n libraries + gconv ($(du -sh "$ov" | cut -f1))"

# --- Debian's stock ld.so of the same version (= the APK's libpmbld.so) ---------------------------
debx="$out/libc6-deb"
mkdir -p "$debx" "$out/stock-loader"
dpkg-deb -x "$deb" "$debx"
stock=""
for c in "$debx/lib/$TRIPLET/$LD" "$debx/usr/lib/$TRIPLET/$LD"; do
    if [ -f "$c" ] && [ ! -L "$c" ]; then stock="$c"; break; fi
done
[ -n "$stock" ] || die "$LD not found in $(basename "$deb")"
verify_sha256 "$stock" "$LOADER_SHA256"
install -m 0755 "$stock" "$out/stock-loader/libpmbld.so"
rm -rf "$debx"
stock="$out/stock-loader/libpmbld.so"
log "stock loader from $(basename "$deb") = the APK's libpmbld.so (sha256 $LOADER_SHA256)"

# --- self-tests ----------------------------------------------------------------------------------
log "compiling self-tests"
gcc -std=gnu11 -O1 -Wall -Wextra -Werror -o "$out/glibc-rootfs-test" "$PB/src/glibc-rootfs-test.c"
gcc -std=gnu11 -O1 -Wall -Wextra -Werror -o "$out/glibc-execve-test" "$PB/src/glibc-execve-test.c"
gcc -std=gnu11 -O1 -Wall -Wextra -Werror -static -o "$out/glibc-execve-test-static" \
    "$PB/src/glibc-execve-test.c"

troot="$(mktemp -d /tmp/pmbos-glibc-selftest.XXXXXX)"
log "PMBOS_ROOTFS self-test (fake rootfs $troot)"
if ! env -u PMBOS_ROOTFS -u PMBOS_LOADER -u TZ -u TZDIR -u LD_LIBRARY_PATH -u LD_PRELOAD \
        "$ov/lib/$LD" --library-path "$ov/usr/lib/$TRIPLET" \
        "$out/glibc-rootfs-test" --selftest "$troot" /bin/sh; then
    die "glibc PMBOS_ROOTFS self-test failed (fake rootfs kept in $troot)"
fi
rm -rf "$troot"

log "execve redirect: unit test of the patch logic + classification of real binaries"
bash "$PB/tests/execve-redirect-hosttest.sh" --cc gcc \
    --elf "loader:$out/glibc-execve-test" --elf "plain:$out/glibc-execve-test-static" \
    --elf "plain:$stock" --elf "loader:$libc" --elf "loader:$(readlink -f /bin/dash)" \
    || die "execve redirect unit test failed"
for ld in "$ov/lib/$LD" "$stock"; do
    tdir="$(mktemp -d /tmp/pmbos-execve-selftest.XXXXXX)"
    log "execve redirect self-test, PMBOS_LOADER=$ld"
    if ! env -u PMBOS_ROOTFS -u PMBOS_LOADER -u PMBOS_LOADER_LIBPATH -u TZ -u TZDIR \
            -u LD_LIBRARY_PATH -u LD_PRELOAD \
            "$ld" --library-path "$ov/usr/lib/$TRIPLET" "$out/glibc-execve-test" \
            --selftest "$tdir" "$ld" "$ov/usr/lib/$TRIPLET" "$out/glibc-execve-test-static"; then
        die "execve redirect self-test failed with PMBOS_LOADER=$ld (scratch dir kept in $tdir)"
    fi
    rm -rf "$tdir"
done

printf '%s\n' "$debver" > "$out/VERSION"
rm -rf "$srcroot"
log "glibc $debver + pmbos-rootfs + pmbos-execve OK"
