#!/usr/bin/env bash
# Stage "venus-android" (runs directly on an x86_64 GitHub runner, NOT in a build container): the Android-side half of
# GPU acceleration for non-Adreno GPUs (Mali...).
#   virglrenderer (Venus only, no OpenGL/virgl, vtest transport) built with the Android NDK for arm64 bionic:
#     bin/virgl_test_server   - listens on a unix socket; Mesa's Venus Vulkan driver (pack mesa, "virtio") in the
#                               glibc/box64 world connects to it (VN_DEBUG=vtest)
#     bin/virgl_render_server - spawned by the test server (RENDER_SERVER_EXEC_PATH), runs the Vulkan commands on the
#                               device's own Vulkan driver (libvulkan.so, dlopen'ed) with AHardwareBuffer-backed memory
#   libepoxy is linked statically (virglrenderer needs it at build time only; no EGL/GLX is used).
# Output: $DIST/venus-android-<ver>.tar.xz with both executables (renamed to lib*.so for the APK's jniLibs:
# Android only executes files from the app's nativeLibraryDir) + licenses. Not a runtime pack: the APK ships it.
#
# Inputs (env): ANDROID_NDK_HOME (or ANDROID_NDK_LATEST_HOME), OUT (output dir), WORK (scratch dir),
#               VIRGL_VERSION / VIRGL_URL / VIRGL_SHA256, LIBEPOXY_VERSION / LIBEPOXY_URL / LIBEPOXY_SHA256 (versions.env).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$here/versions.env"
log() { echo "[venus-android] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
[ -n "$NDK" ] && [ -d "$NDK" ] || die "Android NDK not found (ANDROID_NDK_HOME / ANDROID_NDK_LATEST_HOME)"
API=30
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$TC/aarch64-linux-android$API-clang" ] || die "NDK clang for API $API missing in $TC"
WORK="${WORK:-$PWD/work/venus-android}"
OUT="${OUT:-$PWD/work/dist}"
MESON="${MESON:-meson}"
command -v "$MESON" >/dev/null || die "meson missing"
command -v ninja >/dev/null || die "ninja missing"

rm -rf "$WORK"
mkdir -p "$WORK/dl" "$WORK/src" "$WORK/prefix" "$OUT"

fetch() { # url sha256 dest
    curl -fsSL --retry 3 -o "$3" "$1" || die "download failed: $1"
    echo "$2  $3" | sha256sum -c - >/dev/null || die "sha256 mismatch: $1"
}
log "NDK $(basename "$NDK"), virglrenderer $VIRGL_VERSION, libepoxy $LIBEPOXY_VERSION"
fetch "$VIRGL_URL" "$VIRGL_SHA256" "$WORK/dl/virglrenderer.tar.gz"
fetch "$LIBEPOXY_URL" "$LIBEPOXY_SHA256" "$WORK/dl/libepoxy.tar.gz"
tar -xzf "$WORK/dl/virglrenderer.tar.gz" -C "$WORK/src"
tar -xzf "$WORK/dl/libepoxy.tar.gz" -C "$WORK/src"
VR="$(find "$WORK/src" -maxdepth 1 -type d -name 'virglrenderer-*' -print -quit)"
EP="$(find "$WORK/src" -maxdepth 1 -type d -name 'libepoxy-*' -print -quit)"
[ -d "$VR" ] && [ -d "$EP" ] || die "unexpected source layout"

for p in "$here/patches/virglrenderer-$VIRGL_VERSION-android-"*.patch; do
    [ -f "$p" ] || die "no Android patches for virglrenderer $VIRGL_VERSION"
    log "applying $(basename "$p")"
    (cd "$VR" && patch -p1 --fuzz=0 < "$p" >/dev/null)
done

cross="$WORK/android-arm64.ini"
cat > "$cross" <<EOF
[binaries]
c = '$TC/aarch64-linux-android$API-clang'
cpp = '$TC/aarch64-linux-android$API-clang++'
ar = '$TC/llvm-ar'
strip = '$TC/llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-D__TERMUX__=1', '-fPIE']
c_link_args = ['-fPIE', '-pie']
cpp_args = ['-D__TERMUX__=1', '-fPIE']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
export PKG_CONFIG_LIBDIR="$WORK/prefix/lib/pkgconfig"
export PKG_CONFIG_PATH=

log "libepoxy (static, no EGL/GLX)"
"$MESON" setup "$WORK/build-epoxy" "$EP" --cross-file "$cross" --prefix="$WORK/prefix" --libdir=lib \
    --buildtype=release -Ddefault_library=static -Degl=no -Dglx=no -Dx11=false -Dtests=false \
    > "$WORK/epoxy-setup.log" 2>&1 || { tail -n 40 "$WORK/epoxy-setup.log" >&2; die "libepoxy setup failed"; }
ninja -C "$WORK/build-epoxy" install > "$WORK/epoxy-build.log" 2>&1 \
    || { tail -n 40 "$WORK/epoxy-build.log" >&2; die "libepoxy build failed"; }

log "virglrenderer (Venus, vtest, thread render-server workers)"
"$MESON" setup "$WORK/build-vr" "$VR" --cross-file "$cross" --prefix="$WORK/prefix" --libdir=lib \
    --buildtype=release -Db_ndebug=true -Ddefault_library=static \
    -Dplatforms=[] -Dvenus=true -Dvulkan-dload=true -Drender-server-worker=thread \
    -Ddrm-renderers=[] -Dvideo=false -Dtests=false -Dminigbm_allocation=false \
    > "$WORK/vr-setup.log" 2>&1 || { tail -n 60 "$WORK/vr-setup.log" >&2; die "virglrenderer setup failed"; }
ninja -C "$WORK/build-vr" > "$WORK/vr-build.log" 2>&1 \
    || { tail -n 80 "$WORK/vr-build.log" >&2; die "virglrenderer build failed"; }

test_server="$(find "$WORK/build-vr" -type f -name virgl_test_server -print -quit)"
render_server="$(find "$WORK/build-vr" -type f -name virgl_render_server -print -quit)"
[ -n "$test_server" ] && [ -n "$render_server" ] || die "virgl_test_server / virgl_render_server not built"

stage="$WORK/out/venus-android-$VIRGL_VERSION"
mkdir -p "$stage"
cp "$test_server" "$stage/libpmbvenus.so"
cp "$render_server" "$stage/libpmbvenusrs.so"
"$TC/llvm-strip" --strip-unneeded "$stage/libpmbvenus.so" "$stage/libpmbvenusrs.so"
cp "$VR/COPYING" "$stage/COPYING.virglrenderer"
cp "$EP/COPYING" "$stage/COPYING.libepoxy"
{
    echo "virglrenderer $VIRGL_VERSION ($VIRGL_URL)"
    echo "libepoxy $LIBEPOXY_VERSION ($LIBEPOXY_URL)"
    echo "Android NDK $(basename "$NDK"), API $API, arm64-v8a"
    echo "patches:"; for p in "$here/patches/virglrenderer-$VIRGL_VERSION-android-"*.patch; do echo "  $(basename "$p")"; done
    echo "libpmbvenus.so = virgl_test_server, libpmbvenusrs.so = virgl_render_server"
} > "$stage/BUILDINFO.txt"

# sanity: arm64 PIE executables that only need bionic system libraries (Vulkan / libandroid are dlopen'ed)
for f in "$stage/libpmbvenus.so" "$stage/libpmbvenusrs.so"; do
    file -b "$f" | grep -q 'ARM aarch64' || die "$(basename "$f") is not arm64"
    needed="$("$TC/llvm-readelf" -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
    log "$(basename "$f") needs: $needed"
    for n in $needed; do
        case "$n" in libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libvulkan.so) ;; *) die "$(basename "$f") needs $n" ;; esac
    done
done

tar -C "$WORK/out" -cJf "$OUT/venus-android-$VIRGL_VERSION.tar.xz" "venus-android-$VIRGL_VERSION"
log "built $OUT/venus-android-$VIRGL_VERSION.tar.xz ($(du -h "$OUT/venus-android-$VIRGL_VERSION.tar.xz" | cut -f1))"
