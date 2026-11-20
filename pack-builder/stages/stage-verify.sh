#!/usr/bin/env bash
# Stage "verify" (arm64 container): installs every archive from $DIST with the reference
# installer (packtool.py install = what the on-device runtime does: extract, symlinks,
# chmod, PT_INTERP rewrite, @ROOTFS@ substitution) into a scratch runtime dir whose path
# differs from any build path, then smoke-tests the result:
#   - box64 executes through the rewritten PT_INTERP using only imagefs libraries
#   - libpmbshm.so passes its self-test when loaded by the imagefs loader
#   - the imagefs glibc honours PMBOS_ROOTFS (the shipped /etc files, zoneinfo and
#     <imagefs>/bin/sh, which itself runs through its rewritten PT_INTERP)
#   - LOADER mode (Android targetSdk >= 29): box64 started the way the launcher does
#     (<stock ld.so = APK libpmbld.so> --library-path ... --argv0 ... box64) and the imagefs
#     glibc checks again with every exec redirected through PMBOS_LOADER
#   - patched libxcb, no leftover @ROOTFS@ tokens, ICD manifest points at a real file
#   - optional: `box64 wine --version`, direct and in LOADER mode (PMB_VERIFY_WINE=1 forces
#     failure on error)
PB_LOG_PREFIX=verify
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
need_cmd python3
[ -x "$BUILD/pmbshm/pmbshm-test" ] || die "run stage pmbshm first (self-test binary missing)"
[ -x "$BUILD/glibc/glibc-rootfs-test" ] || die "run stage glibc first (self-test binary missing)"
stock="$BUILD/glibc/stock-loader/libpmbld.so"
[ -x "$stock" ] || die "run stage glibc first (stock loader missing)"
verify_sha256 "$stock" "$LOADER_SHA256"

rt="$(mktemp -d /tmp/pmbos-verify-runtime.XXXXXX)"
trap 'rm -rf "$rt"' EXIT

archives=("$DIST"/*.tar.xz)
[ "${#archives[@]}" -gt 0 ] || die "no archives in $DIST (run stage post)"
imagefs_archive=("$DIST"/imagefs-*.tar.xz)
[ "${#imagefs_archive[@]}" = 1 ] || die "expected exactly one imagefs archive"
python3 "$PACKTOOL" install --runtime "$rt" "${imagefs_archive[0]}"
for a in "${archives[@]}"; do
    [ "$a" = "${imagefs_archive[0]}" ] && continue
    python3 "$PACKTOOL" install --runtime "$rt" "$a"
done

fs="$rt/imagefs"
libpath="$fs/usr/lib/aarch64-linux-gnu:$fs/usr/lib"
run_clean() { env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH="$libpath" "$@"; }

log "box64 through the rewritten PT_INTERP"
out="$(run_clean "$fs/usr/bin/box64" --version 2>&1)" || die "box64 failed to start: $out"
grep -qi box64 <<<"$out" || die "unexpected box64 output: $out"
log "  $out"

log "libpmbshm self-test under the imagefs loader"
shm="$fs/tmp/pmbshm"
mkdir -p "$shm"
run_clean env PMBOS_SHM_DIR="$shm" "$fs/lib/ld-linux-aarch64.so.1" --library-path "$libpath" \
    --preload "$fs/usr/lib/libpmbshm.so" "$BUILD/pmbshm/pmbshm-test" "$shm" \
    || die "libpmbshm self-test failed inside the installed imagefs"

log "imagefs glibc: PMBOS_ROOTFS relocation"
grep -q PMBOS_ROOTFS "$fs/usr/lib/aarch64-linux-gnu/libc.so.6" || die "imagefs libc.so.6 is not the PMBOS_ROOTFS build"
out="$(run_clean env PMBOS_ROOTFS="$fs" "$fs/bin/sh" -c 'echo "sh:$PMBOS_ROOTFS"' 2>&1)" \
    || die "imagefs /bin/sh failed to start: $out"
[ "$out" = "sh:$fs" ] || die "unexpected imagefs /bin/sh output: $out"
# (the full --selftest ran in stage glibc on these exact files; its "unset" half would mix the
# container's /bin/sh + loader with the imagefs libc here, so only the imagefs mode runs)
run_clean env PMBOS_ROOTFS="$fs" "$fs/lib/ld-linux-aarch64.so.1" --library-path "$libpath" \
    "$BUILD/glibc/glibc-rootfs-test" --imagefs \
    || die "shipped imagefs /etc files or /bin/sh do not work through PMBOS_ROOTFS"

log "LOADER mode: stock ld.so (= APK libpmbld.so) + imagefs glibc"
grep -q PMBOS_LOADER_LIBPATH "$fs/usr/lib/aarch64-linux-gnu/libc.so.6" || die "imagefs libc.so.6 lacks the execve redirect"
loader_env=(PMBOS_LOADER="$stock" PMBOS_LOADER_LIBPATH="$libpath" PMBOS_ROOTFS="$fs")
out="$(run_clean env "${loader_env[@]}" "$stock" --library-path "$libpath" --argv0 "$fs/usr/bin/box64" \
    "$fs/usr/bin/box64" --version 2>&1)" || die "box64 failed to start through the stock loader: $out"
grep -qi box64 <<<"$out" || die "unexpected box64 output (loader mode): $out"
log "  $out"
# system()/popen() -> $PMBOS_ROOTFS/bin/sh, redirected through the stock loader
run_clean env "${loader_env[@]}" "$stock" --library-path "$libpath" \
    "$BUILD/glibc/glibc-rootfs-test" --imagefs \
    || die "imagefs glibc checks fail in LOADER mode (PMBOS_LOADER redirect)"

log "static checks"
xcb=("$fs"/usr/lib/aarch64-linux-gnu/libxcb.so.1.*)
[ "${#xcb[@]}" -gt 0 ] && grep -q PMBOS_TMPDIR "${xcb[@]}" || die "imagefs libxcb is not the patched build"
# captured, not "| grep -q .": under pipefail a SIGPIPE'd writer would turn a hit into a pass
leftover="$(grep -rlI --exclude-dir=wine-addons '@ROOTFS@' "$fs/etc" "$fs/opt" 2>/dev/null || true)"
[ -z "$leftover" ] || die "unsubstituted @ROOTFS@ tokens remain after install: ${leftover//$'\n'/ }"
for icd in "$fs"/opt/mesa-*/share/vulkan/icd.d/freedreno_icd.aarch64.json; do
    lib="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ICD"]["library_path"])' "$icd")"
    [ -f "$lib" ] || die "ICD $icd points at missing $lib"
    log "  ICD OK: $lib"
done
grep -q "<dir>$fs/usr/share/fonts</dir>" "$fs/etc/fonts/fonts.conf" || die "fonts.conf not patched"

wine_mode="${PMB_VERIFY_WINE:-auto}"
if [ "$wine_mode" != 0 ]; then
    for w in "$fs"/opt/wine-*/bin/wine; do
        wdir="$(dirname "$(dirname "$w")")"
        mkdir -p "$fs/tmp/home"
        for mode in direct loader; do
            log "wine smoke test: $(basename "$wdir") ($mode mode)"
            if [ "$mode" = direct ]; then
                launch=("$fs/usr/bin/box64")
            else
                launch=(env "${loader_env[@]}" "$stock" --library-path "$libpath" --argv0 "$fs/usr/bin/box64"
                        "$fs/usr/bin/box64")
            fi
            if wout="$(run_clean env HOME="$fs/tmp/home" PMBOS_TMPDIR="$fs/tmp" PMBOS_ROOTFS="$fs" BOX64_NOBANNER=1 BOX64_LOG=0 \
                    BOX64_LD_LIBRARY_PATH="$fs/usr/lib/box64-x86_64-linux-gnu:$wdir/lib/wine/x86_64-unix" \
                    BOX64_RCFILE="$fs/etc/box64.box64rc" \
                    timeout 300 "${launch[@]}" "$w" --version 2>&1)" && grep -q '^wine-' <<<"$wout"; then
                log "  $(echo "$wout" | grep '^wine-' | head -n1)"
            elif [ "$wine_mode" = 1 ]; then
                die "wine --version under box64 ($mode mode) failed: $wout"
            else
                warn "wine --version under box64 ($mode mode) failed (expected under qemu-user; set PMB_VERIFY_WINE=1 on native arm64 to enforce): $(echo "$wout" | tail -n 3)"
            fi
        done
    done
fi
log "verification passed for ${#archives[@]} archives"
